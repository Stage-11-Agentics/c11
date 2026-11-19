#!/bin/zsh
# Push kitty keyboard flags 1 (disambiguate), read one key event, pop, show bytes.
printf '\e[>1u'
echo "KITTY_READY press Escape"
read -rs -t 8 -d u x
printf '\e[<u'
print -r -- "KITTY_KEY_BYTES=$(print -rn -- "$x" | od -An -c | tr -s ' ')"
