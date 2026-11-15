# The landing-page demo: one task from clone to finish, recorded against the real CLI.
# Typing is scripted. Every pause after Enter is the command actually running.
# Record with site/demo/record.sh, which creates DEMO_DIR and puts microvm on PATH.

Output public/demo/microvm-workflow.mp4
Output public/demo/microvm-workflow.webm

Require microvm

Set Shell "bash"
Set FontFamily "IBM Plex Mono, Menlo, monospace"
Set FontSize 15
Set LineHeight 1.35
Set Width 1440
Set Height 820
Set Padding 40
Set Framerate 30
Set TypingSpeed 32ms
Set CursorBlink false
Set Theme { "name": "microvm", "background": "#000000", "foreground": "#F2F2F0", "cursor": "#F0A202", "selection": "#2A2A28", "black": "#000000", "brightBlack": "#6E6E68", "red": "#E07A5F", "brightRed": "#E9967F", "green": "#A8C686", "brightGreen": "#BED6A2", "yellow": "#F0A202", "brightYellow": "#F5BA45", "blue": "#A3A39C", "brightBlue": "#C8C8C0", "magenta": "#C8C8C0", "brightMagenta": "#F2F2F0", "cyan": "#A3A39C", "brightCyan": "#C8C8C0", "white": "#C8C8C0", "brightWhite": "#F2F2F0" }

Hide
Type `export PS1='$ ' && cd "$DEMO_DIR" && clear`
Enter
Sleep 300ms
Show

Sleep 600ms
Type "cat README.md"
Enter
Wait@10s /^\$$/
Sleep 1s

Type "microvm clone . demo"
Enter
Wait@60s /^\$$/
Sleep 1.4s

Type "microvm exec demo -- uname -sr"
Enter
Wait@20s /^\$$/
Sleep 900ms

Type "microvm exec demo -- sed -i 's/from the host/from a microVM/' README.md"
Enter
Wait@20s /^\$$/
Sleep 600ms

Type "microvm diff demo"
Enter
Wait@30s /^\$$/
Sleep 1.8s

Type "microvm finish demo"
Enter
Wait@30s /^\$$/
Sleep 1.4s

Type "cat README.md"
Enter
Wait@10s /^\$$/
Sleep 3.5s
