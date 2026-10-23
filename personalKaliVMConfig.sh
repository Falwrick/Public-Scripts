#!/bin/bash
# Kali provisioning script — run as root from /home/kali

if [ "$EUID" -ne 0 ]; then
  echo "Please run with sudo"
  exit 13
fi

# Make the script deterministic regardless of where it's launched,
# and keep apt fully non-interactive (no config-file prompts mid-run).
cd /home/kali || exit 1
export DEBIAN_FRONTEND=noninteractive

# Proper array (was a single-element array that happened to word-split)
packagesToInstall=(rlwrap ripgrep ffuf cupp zaproxy feroxbuster neovim
  golang-go bat penelope eza docker-compose snmp-mibs-downloader sliver)

PKG_LIST=/home/kali/packageList.txt
: >"$PKG_LIST"
for package in "${packagesToInstall[@]}"; do
  echo "$package" >>"$PKG_LIST"
done

apt update
apt -y upgrade
apt install -y --reinstall fuse
apt update --fix-missing

# Install the apt package set EARLY so go/docker/snmp tools below actually exist.
xargs -a "$PKG_LIST" apt install -y
download-mibs # provided by snmp-mibs-downloader

# export so pipx (a child process) actually sees it
export PIPX_BIN_DIR=/usr/bin
pipx install uploadserver

mkdir -p githubTools
cd githubTools
git clone https://github.com/Dewalt-arch/pimpmykali
cd pimpmykali
./pimpmykali.sh --autonoroot

ln -s /usr/share/wordlists/ /home/kali/wordlists
echo "autoload -U compinit; compinit" >>/root/.zshrc
echo "autoload -U compinit; compinit" >>/home/kali/.zshrc
echo "alias vim='nvim'" >>/home/kali/.zshrc
echo "alias HTBAConnect='sudo openvpn /home/kali/Desktop/HTBA.ovpn'" >>/home/kali/.zshrc
echo "alias grep='rg'" >>/home/kali/.zshrc
echo "alias ls='eza'" >>/home/kali/.zshrc
echo "alias cat='batcat'" >>/home/kali/.zshrc
echo 'if [ -z "$TMUX" ]; then' >>/home/kali/.zshrc
echo '    tmux attach-session -t main || tmux new-session -s main' >>/home/kali/.zshrc
echo 'fi' >>/home/kali/.zshrc
echo 'export PATH=$PATH:/usr/local/go/bin' >>/home/kali/.zshrc
echo 'export PATH=$PATH:$(go env GOPATH)/bin' >>/home/kali/.zshrc

# Go tooling (modern module-mode installs; binaries land in GOBIN=/usr/bin)
export GOBIN=/usr/bin
go install github.com/shelld3v/aquatone@latest
go install github.com/sensepost/gowitness@latest
go install github.com/bitquark/shortscan/cmd/shortscan@latest
cd ..

wget https://github.com/antonioCoco/RunasCs/releases/download/v1.5/RunasCs.zip
unzip RunasCs.zip
git clone https://github.com/urbanadventurer/username-anarchy.git
git clone https://github.com/ropnop/kerbrute.git
git clone https://github.com/Greenwolf/ntlm_theft.git
git clone https://github.com/stealthsploit/OneRuleToRuleThemStill.git
git clone https://github.com/mrdanielvelez/newtmux.git
wget https://raw.githubusercontent.com/Falwrick/seasonWordlistGen/refs/heads/main/gen_season_wordlist.sh
chmod +x /home/kali/githubTools/gen_season_wordlist.sh
bash /home/kali/githubTools/gen_season_wordlist.sh -o /usr/share/wordlists/seasons.txt

# Apply each best66 rule to the whole wordlist in order: the first (most likely)
# rule hits every password before moving on. Good for web/network bruteforce.
while IFS= read -r rule; do
  echo "$rule" >/tmp/current.rule
  hashcat --stdout -r /tmp/current.rule /usr/share/wordlists/seasons.txt
done </usr/share/hashcat/rules/best66.rule >/usr/share/wordlists/seasonB66RuleMajor.txt
cd ..

wget https://raw.githubusercontent.com/Falwrick/Public-Scripts/refs/heads/main/initialNmap.sh
chmod +x initialNmap.sh
chown kali:kali initialNmap.sh

git clone https://github.com/LazyVim/starter /home/kali/.config/nvim
rm -rf /home/kali/.config/nvim/.git

# LazyVim: pin colorscheme to Tokyo Night "night" (matches the rest of the stack;
# LazyVim otherwise defaults to the lighter "moon" variant)
cat >/home/kali/.config/nvim/lua/plugins/colorscheme.lua <<'EOF'
return {
  { "folke/tokyonight.nvim", opts = { style = "night" } },
  { "LazyVim/LazyVim", opts = { colorscheme = "tokyonight-night" } },
}
EOF

mkdir -p /home/kali/.local/bin
chmod +x /home/kali/githubTools/newtmux/newtmux.sh
mv /home/kali/githubTools/newtmux/newtmux.sh /home/kali/.local/bin/newtmux

# Readable-log renderer. A raw `pipe-pane` capture is escape soup: truecolor SGR,
# OSC titles, bracketed-paste, and — worst — carriage-return redraws from the
# 2-line prompt / zsh-autosuggestions / zsh-syntax-highlighting, which leave the
# logged command line wrong (e.g. a never-run autosuggestion glued on). Stripping
# escapes (sed/ansi2txt) does NOT fix that, and `col -b` corrupts UTF-8. ttyclean
# emulates the intra-line ops a terminal would (CR, BS, erase-to-EOL, cursor cols,
# tabs) and drops the colour noise, so each newline-delimited line renders as its
# final on-screen state. Pure python3 (no deps), UTF-8-safe, and because it's
# line-buffered it works as a live filter. Bonus: progress bars (wget/nmap/ffuf)
# collapse to their final line instead of flooding the log.
cat >/home/kali/.local/bin/ttyclean <<'TTYCLEAN'
#!/usr/bin/env python3
"""Render a raw terminal capture into clean, readable text (line by line).
Usage: ttyclean [FILE]   (no FILE => read stdin; used as a tmux pipe-pane filter)."""
import sys, re

OSC = re.compile(r'\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)')   # title/OSC sequences
CSI = re.compile(r'\x1b\[([0-9;?]*)([A-Za-z])')          # generic CSI

def render_line(raw):
    raw = OSC.sub('', raw)
    buf, col, i = [], 0, 0
    while i < len(raw):
        c = raw[i]
        if c == '\r': col = 0; i += 1; continue
        if c == '\b': col = max(0, col - 1); i += 1; continue
        if c == '\x1b':
            m = CSI.match(raw, i)
            if m:
                p, f = m.group(1), m.group(2)
                if f == 'K':                              # erase in line
                    mode = p or '0'
                    if mode == '0': del buf[col:]
                    elif mode == '1':
                        for j in range(min(col, len(buf))): buf[j] = ' '
                    elif mode == '2': buf[:] = []
                elif f in 'CD':                           # cursor fwd / back
                    n = int(p or '1'); col = col + n if f == 'C' else max(0, col - n)
                elif f == 'G':                            # absolute column
                    col = max(0, int(p or '1') - 1)
                i = m.end(); continue
            i += 1; continue                              # lone ESC / unhandled
        if c == '\t':
            nxt = (col // 8 + 1) * 8
            while col < nxt:
                if col < len(buf): buf[col] = ' '
                else: buf.append(' ')
                col += 1
            i += 1; continue
        if ord(c) < 32: i += 1; continue                  # other control: drop
        if col < len(buf): buf[col] = c
        else: buf.extend(' ' * (col - len(buf))); buf.append(c)
        col += 1; i += 1
    return ''.join(buf).rstrip()

def main():
    src = open(sys.argv[1], 'rb') if len(sys.argv) > 1 else sys.stdin.buffer
    for bline in src:                # binary iter splits on \n only; \r is preserved
        line = bline.decode('utf-8', 'replace')
        nl = line.endswith('\n')
        sys.stdout.write(render_line(line[:-1] if nl else line) + ('\n' if nl else ''))
        sys.stdout.flush()

if __name__ == '__main__':
    main()
TTYCLEAN
chmod +x /home/kali/.local/bin/ttyclean

# Auto-logging helper: pipe the calling pane through ttyclean into ~/Logs
cat >/home/kali/.local/bin/tmux-autolog <<'AUTOLOG'
#!/usr/bin/env bash
# Capture the calling tmux pane to ~/Logs as clean, readable text (engagement evidence).
mkdir -p "$HOME/Logs"
tmux pipe-pane -o "$HOME/.local/bin/ttyclean >> $HOME/Logs/#S-#I-#P.log"
AUTOLOG
chmod +x /home/kali/.local/bin/tmux-autolog

# tpm for the logging plugin
git clone https://github.com/tmux-plugins/tpm /home/kali/.tmux/plugins/tpm

# ── tmux: Tokyo Night + Ctrl+Space prefix + auto-logging ─────────────
cat >/home/kali/.tmux.conf <<'TMUXCONF'
# ~/.tmux.conf — Tokyo Night · rounded pills · Ctrl+Space prefix

# Prefix: Ctrl+b -> Ctrl+Space
unbind C-b
set -g prefix C-Space
bind C-Space send-prefix

# Core behaviour
set -g mouse on
set -s set-clipboard on
setw -g mode-keys vi
bind-key -T copy-mode-vi v send-keys -X begin-selection
bind-key -T copy-mode-vi y send-keys -X copy-pipe-and-cancel "xclip -selection clipboard -i"
bind-key -T copy-mode-vi MouseDragEnd1Pane send-keys -X copy-pipe-and-cancel "xclip -selection clipboard -i"

# Sensible defaults (replaces the tmux-sensible plugin)
set -g default-terminal "tmux-256color"
set -ag terminal-overrides ",xterm-256color:RGB"
set -sg escape-time 10
set -g history-limit 50000
set -g display-time 2000
set -g status-interval 5
set -g focus-events on
set -g base-index 1
setw -g pane-base-index 1
set -g renumber-windows on
bind r source-file ~/.tmux.conf \; display-message " ~/.tmux.conf reloaded"

# Auto-logging: capture every pane to ~/Logs the moment it's created
set-hook -g session-created 'run-shell "~/.local/bin/tmux-autolog"'
set-hook -g after-new-window 'run-shell "~/.local/bin/tmux-autolog"'
set-hook -g after-split-window 'run-shell "~/.local/bin/tmux-autolog"'

# Status bar — Tokyo Night
set -g status on
set -g status-position bottom
set -g status-justify left
set -g status-style "bg=#1a1b26,fg=#c0caf5"
set -g status-left-length 100
set -g status-right-length 200
set -g status-left "#{?client_prefix,#[fg=#f7768e],#[fg=#bb9af7]}#[bg=#1a1b26]#{?client_prefix,#[bg=#f7768e],#[bg=#bb9af7]}#[fg=#1a1b26,bold] #S #{?client_prefix,#[fg=#f7768e],#[fg=#bb9af7]}#[bg=#1a1b26] "
set -g window-status-separator " "
set -g window-status-format "#[fg=#292e42,bg=#1a1b26]#[fg=#7f87b3,bg=#292e42] #I #W #[fg=#292e42,bg=#1a1b26]"
set -g window-status-current-format "#[fg=#7aa2f7,bg=#1a1b26]#[fg=#1a1b26,bg=#7aa2f7,bold] #I #W #[fg=#7aa2f7,bg=#1a1b26]"
set -g status-right "#[fg=#3b4261,bg=#1a1b26]#[fg=#c0caf5,bg=#3b4261] #(whoami)@#H #[fg=#3b4261,bg=#1a1b26] #[fg=#7aa2f7,bg=#1a1b26]#[fg=#1a1b26,bg=#7aa2f7,bold] %H:%M #[fg=#7aa2f7,bg=#1a1b26]"

# Accents
set -g pane-border-style "fg=#292e42"
set -g pane-active-border-style "fg=#7aa2f7"
set -g message-style "bg=#292e42,fg=#c0caf5"
set -g message-command-style "bg=#292e42,fg=#c0caf5"
set -g mode-style "bg=#3b4261,fg=#c0caf5"
set -g clock-mode-colour "#7aa2f7"

# Plugins (logging) — tmux-sensible defaults are baked in above
set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'tmux-plugins/tmux-logging'

# Initialize TPM (keep at the very bottom)
run '~/.tmux/plugins/tpm/tpm'
TMUXCONF

# Install the tmux plugins (tmux-logging) non-interactively
HOME=/home/kali TMUX_PLUGIN_MANAGER_PATH=/home/kali/.tmux/plugins/ \
  /home/kali/.tmux/plugins/tpm/bin/install_plugins

# ── Nerd Font (JetBrainsMono) — same typeface as the WezTerm config, and
#    renders the rounded tmux/p10k glyphs inside QTerminal ──
mkdir -p /usr/local/share/fonts/JetBrainsMonoNerdFont
wget -O /tmp/JetBrainsMono.zip \
  https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.zip
unzip -o /tmp/JetBrainsMono.zip -d /usr/local/share/fonts/JetBrainsMonoNerdFont
rm -f /tmp/JetBrainsMono.zip
fc-cache -f

# ── QTerminal: Tokyo Night color scheme + matching font ──────────────
# NOTE: user schemes live in ~/.local/share/qterminal/color-schemes
# (version-independent), NOT ~/.local/share/qtermwidget5 (that's system).
mkdir -p /home/kali/.local/share/qterminal/color-schemes
cat >"/home/kali/.local/share/qterminal/color-schemes/Tokyo Night.colorscheme" <<'SCHEME'
[General]
Description=Tokyo Night
Opacity=1
Wallpaper=

[Background]
Color=26,27,38
[BackgroundIntense]
Color=26,27,38
[Foreground]
Color=192,202,245
[ForegroundIntense]
Color=192,202,245

[Color0]
Color=21,22,30
[Color0Intense]
Color=65,72,104
[Color1]
Color=247,118,142
[Color1Intense]
Color=255,137,157
[Color2]
Color=158,206,106
[Color2Intense]
Color=159,224,68
[Color3]
Color=224,175,104
[Color3Intense]
Color=250,186,74
[Color4]
Color=122,162,247
[Color4Intense]
Color=141,176,255
[Color5]
Color=187,154,247
[Color5Intense]
Color=199,169,255
[Color6]
Color=125,207,255
[Color6Intense]
Color=164,218,255
[Color7]
Color=169,177,214
[Color7Intense]
Color=192,202,245
SCHEME

# Apply scheme + font in qterminal.ini (create/update each key idempotently)
QT_INI=/home/kali/.config/qterminal.org/qterminal.ini
mkdir -p "$(dirname "$QT_INI")"
set_qt_ini() {
  local key="$1" val="$2"
  if grep -q "^${key}=" "$QT_INI" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$QT_INI"
  elif grep -q '^\[General\]' "$QT_INI" 2>/dev/null; then
    sed -i "/^\[General\]/a ${key}=${val}" "$QT_INI"
  else
    printf '[General]\n%s=%s\n' "$key" "$val" >>"$QT_INI"
  fi
}
set_qt_ini colorScheme "Tokyo Night"
set_qt_ini fontFamily "JetBrainsMono Nerd Font Mono"
set_qt_ini fontSize "11"

cd /home/kali
mkdir -p Bloodhound
cd Bloodhound
wget https://github.com/SpecterOps/bloodhound-cli/releases/latest/download/bloodhound-cli-linux-amd64.tar.gz
tar -xvzf bloodhound-cli-linux-amd64.tar.gz
# Stage the bloodhound-cli binary only — don't run `install` here (the Docker
# stack is heavy and not needed on every box). Run `bloodhound-cli install` by
# hand when an engagement calls for it; with the .env pre-staged below, decline
# the overwrite prompt at install time to keep the 0.0.0.0:8181 bind.
# Docker is enabled now so the daemon is already up whenever you do install.
systemctl enable --now docker 2>/dev/null || true

# Bloodhound CLI Port Config
mkdir -p /root/.config/bloodhound
cat >>/root/.config/bloodhound/.env <<'EOF'
BLOODHOUND_HOST=0.0.0.0
BLOODHOUND_PORT=8181
EOF
touch /home/kali/Bloodhound/PORT8181 # File to remind me of changed port
cd /home/kali

# Make sure everything we dropped into /home/kali is owned by kali
chown -R kali:kali /home/kali

rm -f "$PKG_LIST"
rm -f /home/kali/install.sh

# VMware xclip fix
if systemd-detect-virt | grep -q vmware; then
  apt install -y xsel
  mv /usr/bin/xclip /usr/bin/xclip.real 2>/dev/null
  tee /usr/local/bin/xclip >/dev/null <<'EOF'
#!/bin/bash
ARGS="$*"
if [[ "$ARGS" == *"-i"* ]] || [ -p /dev/stdin ]; then
    [[ "$ARGS" == *"clipboard"* ]] && xsel --clipboard --input || xsel --primary --input
else
    [[ "$ARGS" == *"clipboard"* ]] && xsel --clipboard --output || xsel --primary --output
fi
EOF
  chmod +x /usr/local/bin/xclip
fi

shutdown -r now
