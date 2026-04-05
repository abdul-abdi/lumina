# Lumina demo — record with: vhs demo.tape
# Install VHS: brew install charmbracelet/tap/vhs
# Output: demo.gif (embed in README)

Output demo.gif

Require lumina

Set Shell "zsh"
Set FontSize 15
Set Width 1000
Set Height 550
Set Theme "Catppuccin Mocha"
Set Padding 24
Set TypingSpeed 40ms
Set PlaybackSpeed 0.8
Set WindowBar Colorful
Set MarginFill "#1e1e2e"
Set BorderRadius 8
Set Margin 16

# If lumina isn't on PATH after `make install`, build and add it:
# Env PATH ".build/arm64-apple-macosx/debug:/opt/homebrew/bin:/usr/bin:/bin"

# --- Scene 1: Version check ---
Type "lumina --version"
Sleep 300ms
Enter
Sleep 1.5s

# --- Scene 2: Simple command — shows the core concept ---
Type "# Run a command in a disposable Linux VM"
Enter
Sleep 500ms
Type `lumina run "echo hello from Lumina"`
Sleep 400ms
Enter

# VM boot (~1.5s) + exec + teardown
Sleep 5s

# Pause to read the output
Sleep 1.5s

# --- Scene 3: Prove it's a real VM ---
Type "# It's a real aarch64 Linux kernel"
Enter
Sleep 500ms
Type `lumina run "uname -a"`
Sleep 400ms
Enter

Sleep 5s
Sleep 1.5s

# --- Scene 4: Streaming output ---
Type "# Stream output in real time"
Enter
Sleep 500ms
Type `lumina run --stream "echo step 1 && sleep 0.5 && echo step 2 && sleep 0.5 && echo step 3"`
Sleep 400ms
Enter

# Streaming takes ~3s of command time + VM overhead
Sleep 7s
Sleep 1.5s

# --- Scene 5: Resource configuration ---
Type "# Custom resources: 1GB RAM, 4 CPUs, 2 minute timeout"
Enter
Sleep 500ms
Type `lumina run --memory 1GB --cpus 4 --timeout 2m "free -h && nproc"`
Sleep 400ms
Enter

Sleep 6s
Sleep 2s

# --- End: let the final output breathe ---
Sleep 1s
Type "# Every run is fully isolated. VM destroyed after each command."
Enter
Sleep 3s
