# opencodeselector

Switch between vanilla OpenCode and OhMyOpenCode profiles. Linux & macOS.

## Setup

```bash
# 1. Put the script in your PATH
cp chooseopencode.sh ~/.local/bin/chooseopencode
chmod +x ~/.local/bin/chooseopencode

# 2. Add to ~/.bashrc or ~/.zshrc
export OPENCODE_HOME="$HOME/my-project"   # where your package.json / node_modules live
alias oc="chooseopencode"

# 3. Reload
source ~/.bashrc
```

Everything else (prerequisites, binaries, config directories, omo plugin setup) is handled interactively by the script on first run.

## Usage

```
oc                # interactive menu (checks updates, switch profile)
oc omo            # switch to OhMyOpenCode
oc default        # switch to vanilla OpenCode
oc -s             # show current status
oc -u             # update current profile
oc -u all         # update all profiles
oc -c             # check prerequisites only
```

## How it works

Swaps symlinks -- nothing is moved or edited:

```
~/.local/bin/opencode      -> chosen binary
~/.config/opencode         -> ~/.config/opencode-{profile}/
$OPENCODE_HOME/.opencode   -> .opencode-{profile}/  (omo only)
```

`OPENCODE_HOME` defaults to `$PWD` if not set.

