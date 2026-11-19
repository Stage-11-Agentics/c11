#!/bin/zsh
# Spike 0b keystroke driver: N synthesized 'a' keys into the frontmost c11 panel, Return every 80.
N=${1:-2100}; pid=${2:?usage: lat0b.sh <N> <app pid> (g.sh apppid)}
/usr/bin/osascript <<OSA
tell application "System Events"
  tell (first process whose unix id is $pid) to set frontmost to true
  delay 0.5
  repeat with i from 1 to $N
    keystroke "a"
    delay 0.012
    if i mod 80 = 0 then key code 36
  end repeat
end tell
OSA
echo "sent $N"
