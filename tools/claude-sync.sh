#!/bin/sh
# Claude Code hook (SessionStart, UserPromptSubmit; see .claude/settings.json).
# Before every prompt: fetch, fast-forward the current branch, and tell Claude
# what arrived. Claude Code reads CLAUDE.md only when a session starts, so a
# changed CLAUDE.md is printed here in full. Never blocks: it always exits 0.
BASE=release-0.4

cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

head0=$(git rev-parse HEAD)
base0=$(git rev-parse -q --verify "origin/$BASE")

git fetch -q origin 2>/dev/null || exit 0     # offline: say nothing

if git rev-parse -q --verify '@{u}' >/dev/null 2>&1; then
    if ! git merge --ff-only -q '@{u}' >/dev/null 2>&1; then
        echo "Note: $(git branch --show-current) could not fast-forward to its upstream (local changes or diverged); pull by hand."
    fi
fi

head1=$(git rev-parse HEAD)
base1=$(git rev-parse -q --verify "origin/$BASE")

if [ "$head0" != "$head1" ]; then
    echo "git pull brought new commits:"
    git log --oneline "$head0..$head1" | head -20
    if ! git diff --quiet "$head0" "$head1" -- CLAUDE.md; then
        echo
        echo "CLAUDE.md changed; its current text replaces the one loaded at session start:"
        cat CLAUDE.md
    fi
fi

# On a feature branch: report what landed on the release branch meanwhile.
cur=$(git branch --show-current)
if [ "$cur" != "$BASE" ] && [ -n "$base0" ] && [ "$base0" != "$base1" ]; then
    echo "origin/$BASE has new commits that $cur doesn't have yet:"
    git log --oneline "$base0..$base1" | head -20
    if ! git diff --quiet "$base0" "$base1" -- CLAUDE.md; then
        echo
        echo "CLAUDE.md changed on $BASE; its text there:"
        git show "origin/$BASE:CLAUDE.md"
    fi
fi
exit 0
