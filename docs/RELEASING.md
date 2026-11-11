# Versions and releases

One folder, one repository, all versions. Versions are *labels on commits*, not copies of the
project folder. Git keeps every earlier version, and you can get any of them back at any time.

## The pieces

| Piece | What it is |
|---|---|
| `VERSION` | The version being worked on, e.g. `3.0`. `build.sh` writes it into the app's Info.plist. |
| Build number | The number of commits (`git rev-list --count HEAD`), stamped by `build.sh`. It goes up with every commit, so two builds of "3.0" can be told apart (About shows the version). |
| `CHANGELOG.md` | What changed in each version, newest first. |
| Git tag `vX.Y` | A permanent label on the commit that *is* version X.Y. |
| GitHub Release | A page for a tag on GitHub with the notes and, optionally, the zipped app. |

## Day-to-day work

Work on a branch, so `main` always holds the latest finished version:

```bash
git switch -c my-change          # new branch
# …edit, build, test…
git add -A
git commit -m "Describe the change"
git push -u origin my-change     # backup on GitHub; open a pull request there if you like
```

When it's done, merge it into `main`:

```bash
git switch main
git merge my-change
git push
```

## Making a release

1. Put the new number in `VERSION` (e.g. `3.1`) and add a `## [3.1]` section at the top of `CHANGELOG.md`.
2. Run the tests and build: `./test.sh` and `./build.sh --no-dialog --zip`.
3. Commit, tag and push:

   ```bash
   git commit -am "Release 3.1"
   git tag -a v3.1 -m "Starmania 3.1"
   git push origin main v3.1
   ```

4. Optional: create a GitHub Release from the tag, with the changelog section as notes and
   `dist/Starmania-3.1.zip` attached:

   ```bash
   gh release create v3.1 dist/Starmania-3.1.zip --title "Starmania 3.1" --notes-file <(sed -n '/## \[3.1\]/,/## \[/p' CHANGELOG.md | sed '$d')
   ```

   The app is ad-hoc signed (no Apple developer certificate), so on another Mac it has to be
   opened with right-click → Open the first time. Building from source with `./build.sh` avoids that.

## Going back to an earlier version

```bash
git tag                           # list versions
git switch --detach v2.0          # look at (and build) version 2.0
git switch main                   # back to the latest
```

To fix something in an old version without its newer changes: `git switch -c fix-2.0 v2.0`,
fix, then tag `v2.0.1`.

## Version numbers

- **Major** (3.0 → 4.0): the app works differently (like 3.0's new panel and checks).
- **Minor** (3.0 → 3.1): new features, nothing removed.
- **Patch** (3.1 → 3.1.1): bug fixes only.
