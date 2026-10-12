#!/bin/bash
# Two machines, one archive, a delivery you control — the hand-test rig for the
# cross-machine sync work (slices 60, 61, and 48-50).
#
# Sync is not atomic across files: a machine can receive the new manifest.json
# before the record.json it describes. That in-flight window is where the
# interesting behaviour lives (60's witness, 61's indicator, 50's conflicts), and
# it is not reachable by copying an archive in one go. This lets you step it.
#
# Usage:
#   scripts/deliver.sh setup <source.genea> [workdir]
#       Two copies of the archive — "mine" (the machine you watch) and "other" —
#       and one new person written on the other machine, ready to deliver.
#       default workdir: /tmp/GeneaLogic-Delivery
#   scripts/deliver.sh unsettle     Delete mine's .index/, so its next open
#                                   builds a fresh one with no settled witness.
#                                   The state a second machine really starts in
#                                   — and the one `setup` deliberately avoids.
#                                   Run it before `manifest` to hand-test 60b.
#   scripts/deliver.sh manifest     Deliver other's manifest.json alone. The
#                                   records it describes have not arrived: this
#                                   is the in-flight state.
#   scripts/deliver.sh record       Deliver the files the other machine changed,
#                                   including its .index/ — which a provider
#                                   replicates like anything else in the package,
#                                   and which since slice 48 can no longer land
#                                   on top of mine.
#   scripts/deliver.sh race <uid>   Edit a person on MINE, so that the next
#                                   `manifest` delivers a manifest that has never
#                                   heard of that edit — two machines editing
#                                   DIFFERENT records, which is the every-time
#                                   conflict slice 50 exists for. No record ever
#                                   conflicts; only manifest.json does.
#                                   Run: setup -> race <uid> -> manifest -> record.
#   scripts/deliver.sh delete <uid> The same conflict one case over (slice 50b):
#                                   REMOVE a person on MINE, so the manifest
#                                   `other` then delivers still names the record
#                                   you deleted — a file that will never arrive.
#                                   Run: setup -> delete <uid> -> manifest -> record.
#   scripts/deliver.sh revert <uid> Slice 50e: edit a person on MINE, let OTHER take
#                                   the edit and then undo it, so other's record is
#                                   byte-for-byte the version mine replaced — what
#                                   50's merge used to read as a stale manifest.
#                                   Run: setup -> revert <uid> -> manifest -> record,
#                                   with mine open in the app between the steps.
#   scripts/deliver.sh abandon <path>
#                                   Slice 50d: stop waiting for one file that is
#                                   never going to arrive. Stage it by running
#                                   `manifest` and then NOT running `record` —
#                                   the sender went away mid-delivery — check
#                                   `status`, then abandon what it names.
#                                   Run: setup -> manifest -> status -> abandon <path>.
#   scripts/deliver.sh status       What mine's manifest is still waiting for.
#
# Open work/mine.genea in the app between the steps. You can also edit either
# copy yourself with `genea` — the baseline below keeps that safe.
#
# ---------------------------------------------------------------------------
# Two rules this rig has learned by producing a convincing fake bug in a
# hand-test. Both are about the rig standing in for a sync provider honestly:
#
#   1. Compare SHA-256, never size. A same-length edit is invisible to a size
#      comparison. The engine takes that shortcut deliberately — hashing a
#      dataless file materializes it, turning a poll into a whole-archive
#      download — and the rig has no such excuse. (slice 60)
#
#   2. `record` delivers what the OTHER machine changed, measured against the
#      baseline `setup` snapshots — not "every file the delivered manifest
#      names". A provider sends what changed on the sender. A rig that instead
#      restores everything the manifest describes silently reverts any edit made
#      locally in the meantime, and it reads exactly like the engine losing your
#      edit. (slice 61)
#
#   3. `record` delivers other's .index/ too — a provider replicates the whole
#      package — but NEVER onto mine's own machine key. Two real machines cannot
#      share a key (slice 48); this rig can manufacture one if `other` is edited
#      with a plain `genea`, and the result looks exactly like the engine
#      clobbering mine's index. (slice 48)
# ---------------------------------------------------------------------------

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${DELIVER_WORK:-/tmp/GeneaLogic-Delivery}"
MINE="$WORK/mine.genea"
OTHER="$WORK/other.genea"
BASELINE="$WORK/baseline.json"
MINE_KEY="$WORK/mine-machine-key"

# Wrapper: program stdout only (build/progress noise goes to stderr).
genea() { swift run --package-path "$ROOT/GeneaLogicCLI" genea "$@" 2>/dev/null; }

# The same, as the OTHER machine. Since slice 48 each machine keeps its index in
# its own `.index/<machine-key>/`, and that key is derived from the boot volume's
# UUID — so two copies of an archive on one real machine would land on one key
# and the rig could not exercise the thing 48 exists for. The override is a
# testing seam for exactly this (`genea` prints a note to stderr whenever it is
# in force, which this wrapper drops along with the build noise).
genea_other() { GENEALOGIC_TEST_MACHINE_KEY=other genea "$@"; }

# One embedded helper, dispatching on its first argument. Hashing and manifest
# reading are the whole of what this rig does that shell cannot.
py() {
    python3 - "$@" <<'PY'
import hashlib, json, os, shutil, sys

mode = sys.argv[1]


def digest(path):
    if not os.path.isfile(path):
        return None
    return hashlib.sha256(open(path, "rb").read()).hexdigest()


def entries(root):
    return json.load(open(os.path.join(root, "manifest.json")))["files"]


if mode == "baseline":
    # What both machines started from, so `record` can tell "the other machine
    # changed this" from "I changed this".
    root, out = sys.argv[2], sys.argv[3]
    base = {e["path"]: digest(os.path.join(root, e["path"])) for e in entries(root)}
    json.dump({k: v for k, v in base.items() if v}, open(out, "w"))

elif mode == "record":
    mine, other, baseline_path = sys.argv[2], sys.argv[3], sys.argv[4]
    baseline = json.load(open(baseline_path))
    delivered = 0
    for entry in entries(other):
        path = entry["path"]
        dst, src = os.path.join(mine, path), os.path.join(other, path)
        theirs = digest(src)
        if theirs is None:
            continue
        # Rule 2: did the other machine change it? If not, this file is none of
        # the delivery's business, and overwriting it would revert a local edit.
        if theirs == baseline.get(path):
            continue
        if digest(dst) == theirs:
            continue
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copyfile(src, dst)
        delivered += 1
        print("  -> %s" % path)
    print("delivered %d file(s)" % delivered)

elif mode == "index":
    # `.index/` is inside the package, so a provider replicates it like anything
    # else — and nothing in the manifest describes it, which is why this is a
    # walk rather than part of `record` above. Before slice 48 this step landed
    # the other machine's `index.sqlite`, `lock` and `dirty` on top of mine; the
    # point of delivering it is that now it cannot, because the two machines'
    # keys name different directories. Additive on purpose: a provider delivers
    # what the sender has, it does not delete what the receiver has.
    mine, other, mine_key = sys.argv[2], sys.argv[3], sys.argv[4]
    src_root = os.path.join(other, ".index")
    delivered = 0
    for dirpath, _, filenames in os.walk(src_root):
        for name in filenames:
            src = os.path.join(dirpath, name)
            rel = os.path.relpath(src, other)
            # Rule 3: never deliver onto the receiver's OWN machine key. Two real
            # machines cannot share one — that is the invariant 48 established —
            # but this rig can manufacture it, because the header invites you to
            # edit either copy by hand and only `genea_other` sets the override.
            # A plain `genea other.genea` gives other a directory named with
            # *mine's* key, and copying it would land a foreign index on mine's
            # live database: the pre-48 failure, staged by the rig rather than by
            # the engine, and indistinguishable from it afterwards.
            if os.path.normpath(rel).split(os.sep)[1:2] == [mine_key]:
                print("  !! refusing %s — that is MY machine key. Was other edited "
                      "without the override? (use `deliver.sh` or GENEALOGIC_TEST_"
                      "MACHINE_KEY)" % rel)
                continue
            dst = os.path.join(mine, rel)
            if digest(dst) == digest(src):
                continue
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copyfile(src, dst)
            delivered += 1
            print("  -> %s" % rel)
    print("delivered %d index file(s)" % delivered)

elif mode == "rebase":
    # Other has taken a change from mine, so the version it started from for
    # this path is mine's — what `record` must measure other's later edits by.
    baseline_path, path, digest_now = sys.argv[2], sys.argv[3], sys.argv[4]
    baseline = json.load(open(baseline_path))
    baseline[path] = digest_now
    json.dump(baseline, open(baseline_path, "w"))

elif mode == "digest":
    print(digest(sys.argv[2]) or "")

elif mode == "names":
    print(len(json.load(open(sys.argv[2]))["names"]))

elif mode == "status":
    mine = sys.argv[2]
    files = entries(mine)
    outstanding = []
    for entry in files:
        have = digest(os.path.join(mine, entry["path"]))
        if have is None:
            outstanding.append((entry["path"], "absent"))
        elif have != entry.get("sha256"):
            outstanding.append((entry["path"], "differs"))
    print("%d tracked, %d outstanding" % (len(files), len(outstanding)))
    for path, why in outstanding:
        print("  %-7s %s" % (why, path))
PY
}

case "${1:-}" in
setup)
    src="${2:?usage: scripts/deliver.sh setup <source.genea> [workdir]}"
    WORK="${3:-$WORK}"
    MINE="$WORK/mine.genea"
    OTHER="$WORK/other.genea"
    BASELINE="$WORK/baseline.json"
    MINE_KEY="$WORK/mine-machine-key"

    # **Checked before anything is destroyed.** `rm -rf "$WORK"` below is what
    # makes a mistyped source expensive: it takes out the rig you were part way
    # through, and only then does `cp` fail with a message about the source. The
    # way this actually happens is a *step name* where the archive should be —
    # `setup delete PER-…`, from a recalled history line — which is why the error
    # says what a source is supposed to be rather than just that cp failed.
    [ -d "$src" ] && [ -f "$src/manifest.json" ] || {
        echo "not a GeneaLogic archive: $src (no manifest.json)" >&2
        echo "usage: scripts/deliver.sh setup <source.genea> [workdir]" >&2
        exit 1
    }
    # And it must not be *inside* the work directory, which is a real archive and
    # so passes the check above — then `rm -rf "$WORK"` erases the very thing it
    # was told to copy. `setup work/mine.genea` is the obvious way to ask for it.
    src_abs="$(cd "$src" && pwd)"
    work_abs="$(cd "$(dirname "$WORK")" 2>/dev/null && pwd)/$(basename "$WORK")"
    case "$src_abs" in
    "$work_abs" | "$work_abs"/*)
        echo "source is inside the work directory ($work_abs), which setup erases." >&2
        echo "copy it out first, or pass a different workdir." >&2
        exit 1
        ;;
    esac

    echo "Building the genea CLI…"
    swift build --package-path "$ROOT/GeneaLogicCLI" >/dev/null

    rm -rf "$WORK"
    mkdir -p "$WORK"
    cp -R "$src" "$MINE"
    cp -R "$src" "$OTHER"
    # `.index/` is machine-local and rebuildable; a real second machine builds
    # its own, and copying ours would hide what this rig exists to exercise.
    rm -rf "$MINE/.index" "$OTHER/.index"
    # Open mine once so it builds and *settles* an index before anything is
    # delivered. With no settled witness there is no previous state for the
    # delivery to differ from, so the engine reports the outstanding files as
    # missing rather than as an arrival — deliberate since 60b (an archive with
    # no history must not claim one), where before it was 60's exception
    # silently blessing a half-delivered state. Settling first keeps this a
    # delivery; `unsettle` is how you ask for the other case on purpose.
    genea list "$MINE" >/dev/null
    py baseline "$MINE" "$BASELINE"
    # Mine's machine key, snapshotted while `.index/` still holds exactly one
    # directory — its own. `index` below needs it to refuse to deliver onto it,
    # and after the first delivery it can no longer be read off the filesystem
    # unambiguously. Mine deliberately runs on the *real* derivation, not an
    # override: you also open mine.genea in the app, which cannot see the
    # environment, and the two must agree on one key.
    basename "$(ls -d "$MINE"/.index/*/ | head -1)" > "$MINE_KEY"

    # The uid is echoed, not discarded: the hand-test's first step is watching
    # this exact person arrive in the app, and hunting for it in a list of
    # hundreds is not the thing being tested.
    other_surname="From-The-Other-Machine-$(date +%H%M%S)"
    other_uid="$(genea_other person add "$OTHER" \
        --given "Delivered" --surname "$other_surname" | tail -1)"
    echo "mine:  $MINE"
    echo "other: $OTHER"
    echo "       wrote Delivered $other_surname"
    echo "       $other_uid"
    ;;
unsettle)
    # The mirror of `setup`'s settling step, and the reason that step spells out
    # what it is doing: an index with no witness has never accounted for this
    # archive's manifest, so it cannot tell a file that has not arrived from one
    # that is damaged. That is not a corner — it is where every real second
    # machine begins, and any copy, restore or rsync that skips .index/ lands
    # back in it. Slice 60b is what makes the state resolve itself instead of
    # persisting silently, so this is how you drive it.
    [ -d "$MINE" ] || { echo "no $MINE — run 'setup' first" >&2; exit 1; }
    rm -rf "$MINE/.index"
    echo "removed mine's .index/ — its next open builds a fresh, unsettled one"
    ;;
manifest)
    cp "$OTHER/manifest.json" "$MINE/manifest.json"
    echo "delivered manifest.json — the records it describes have not arrived"
    ;;
record)
    py record "$MINE" "$OTHER" "$BASELINE"
    [ -f "$MINE_KEY" ] || { echo "no $MINE_KEY — re-run 'setup'" >&2; exit 1; }
    py index "$MINE" "$OTHER" "$(cat "$MINE_KEY")"
    ;;
race)
    # The conflict a provider cannot avoid: both machines rewrite manifest.json
    # on every mutation, so an edit here and an edit there produce two manifests
    # and only one survives. Before slice 50 the survivor named the pre-edit hash
    # for the record only THIS machine edited, which read as a delivery of a
    # version that exists nowhere — the archive wedged, and the record could not
    # be edited again.
    uid="${2:?usage: scripts/deliver.sh race <PER-uid>   (see 'genea person list')}"
    genea person name add "$MINE" "$uid" \
        --given "Raced" --surname "On-Mine-$(date +%H%M%S)" >/dev/null
    echo "mine edited $uid; other's manifest has never heard of it"
    echo "now: deliver.sh manifest && deliver.sh record"
    ;;
delete)
    # Slice 50b. Before it, the entry for the record you removed here was read as
    # a delivery of a version that exists nowhere: `verify` reported
    # awaiting-delivery on it for ever, its advice forbade the one operation that
    # would clear it, and every later mutation carried the phantom entry forward,
    # so the deletion could never be re-made.
    uid="${2:?usage: scripts/deliver.sh delete <PER-uid>   (see 'genea person list')}"
    genea person remove "$MINE" "$uid" >/dev/null
    echo "mine removed $uid; other's manifest still names it"
    echo "now: deliver.sh manifest && deliver.sh record"
    ;;
revert)
    # Slice 50e. Before it, the merge kept mine's edit — other's manifest named a
    # version mine had replaced, which it read as "other never heard of the edit"
    # — and when other's record then landed with exactly those bytes, nothing
    # revisited the decision: mine served its own edit for ever and `verify`
    # called the reverted record corrupt.
    uid="${2:?usage: scripts/deliver.sh revert <PER-uid>   (see 'genea person list')}"
    path="conclusions/persons/$uid.json"
    before=$(py digest "$MINE/$path")
    genea person name add "$MINE" "$uid" --given "Reverted" --surname "On-Other" >/dev/null
    # Other takes mine's edit (a delivery the other way), then undoes it.
    cp "$MINE/$path" "$OTHER/$path"
    cp "$MINE/manifest.json" "$OTHER/manifest.json"
    genea_other person list "$OTHER" >/dev/null
    last=$(( $(py names "$OTHER/$path") - 1 ))
    genea_other person name remove "$OTHER" "$uid" --index "$last" >/dev/null
    if [ "$(py digest "$OTHER/$path")" != "$before" ]; then
        echo "error: other's record is not byte-identical to mine's original, so this is" >&2
        echo "       not the case 50e covers — re-run 'setup' before reading anything into it" >&2
        exit 1
    fi
    py rebase "$BASELINE" "$path" "$(py digest "$MINE/$path")"
    echo "mine edited $uid; other took the edit and undid it"
    echo "now: deliver.sh manifest (mine still shows its edit) && deliver.sh record"
    echo "     (the edit goes once the record lands — no banner, verify clean)"
    ;;
abandon)
    # Slice 50d — the way out of the one state 50 and 50b deliberately left
    # standing. Reachable from this rig by doing LESS: run `manifest` and never
    # run `record`, which is exactly a sender that went away mid-delivery. Before
    # the slice, `verify` reported awaiting-delivery on that path on every run for
    # ever, its advice forbade `rebaseline` (correctly — for a delivery that is
    # merely slow), and the record was frozen against every further edit.
    #
    # Check `status` first and abandon what it names: the verb refuses anything
    # the archive is not actually waiting for, and that refusal is the half worth
    # seeing too.
    path="${2:?usage: scripts/deliver.sh abandon <archive-relative-path>   (see 'status')}"
    echo "--- before"
    genea verify "$MINE" || true
    genea abandon-delivery "$MINE" "$path"
    echo "--- after"
    genea verify "$MINE" || true
    ;;
status)
    py status "$MINE"
    ;;
*)
    # To the divider, not to a line number — this block has outgrown a hardcoded
    # range once already.
    sed -n '2,/^# ---/p' "${BASH_SOURCE[0]}" | sed '$d'
    exit 1
    ;;
esac
