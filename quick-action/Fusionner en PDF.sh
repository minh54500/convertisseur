out=$(run --merge "${(@on)@}")  # ordre alphabétique (naturel) des noms
notify "$out"
dest=$(print -r -- "$out" | sed -n "s/^→ //p")
[[ -f $dest ]] && open -R "$dest"
