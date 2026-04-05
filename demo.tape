# Lumina demo — record with: vhs demo.tape
# Install VHS: brew install charmbracelet/tap/vhs
# Output: demo.gif (embed in README)

Output demo.gif

Require lumina
Require jq

Set Shell "bash"
Set FontSize 16
Set FontFamily "JetBrains Mono"
Set Width 1100
Set Height 600
Set Theme "Catppuccin Mocha"
Set Padding 24
Set TypingSpeed 35ms
Set PlaybackSpeed 0.8
Set WindowBar Colorful
Set MarginFill "#1e1e2e"
Set BorderRadius 8
Set Margin 16
Set CursorBlink true
Set LoopOffset 80%
Set Framerate 30

# Uncomment and adjust PATH if lumina isn't on your PATH after `make install`:
# Env PATH "$HOME/.local/bin:/opt/homebrew/bin:/usr/bin:/bin"
Env PS1 "$ "

# ═══════════════════════════════════════════════════
# Scene 1: Version
# ═══════════════════════════════════════════════════

Sleep 500ms
Type "lumina --version"
Sleep 200ms
Enter
Sleep 2s

# ═══════════════════════════════════════════════════
# Scene 2: The core concept
# ═══════════════════════════════════════════════════

Type "# Boot a disposable Linux VM, run a command, get the output"
Enter
Sleep 400ms
Type `lumina run "echo hello from Lumina"`
Sleep 300ms
Enter

Sleep 12s

# ═══════════════════════════════════════════════════
# Scene 3: Prove it's real
# ═══════════════════════════════════════════════════

Type "clear"
Enter
Sleep 300ms
Type "# It's a real aarch64 Linux kernel"
Enter
Sleep 400ms
Type `lumina run "uname -srm"`
Sleep 300ms
Enter

Sleep 12s

# ═══════════════════════════════════════════════════
# Scene 4: JSON piping
# ═══════════════════════════════════════════════════

Type "clear"
Enter
Sleep 300ms
Type "# Pipe-friendly: auto-JSON when not a TTY"
Enter
Sleep 400ms
Type `lumina run "echo hello" | jq .`
Sleep 300ms
Enter

Sleep 12s

# ═══════════════════════════════════════════════════
# Scene 5: Streaming
# ═══════════════════════════════════════════════════

Type "clear"
Enter
Sleep 300ms
Type "# Stream output in real time"
Enter
Sleep 400ms
Type `lumina run --stream "echo step 1 && sleep 0.3 && echo step 2 && sleep 0.3 && echo step 3"`
Sleep 300ms
Enter

Sleep 14s

# ═══════════════════════════════════════════════════
# Scene 6: Env vars + resources
# ═══════════════════════════════════════════════════

Type "clear"
Enter
Sleep 300ms
Type "# Custom resources + environment variables"
Enter
Sleep 400ms
Type `lumina run --memory 1GB --cpus 4 -e NAME=Lumina 'echo Hi from $NAME && nproc'`
Sleep 300ms
Enter

Sleep 12s

# ═══════════════════════════════════════════════════
# Scene 7: Closing
# ═══════════════════════════════════════════════════

Type "clear"
Enter
Sleep 300ms
Type "# Every run is fully isolated. VM destroyed after each command."
Enter
Sleep 300ms
Type "# subprocess.run() for virtual machines."
Enter
Sleep 3s
