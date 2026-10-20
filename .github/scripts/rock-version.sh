# The Rock version a checkout declares, read the same way by everything that has
# to know it.
#
# Sourced, not executed, and bash rather than sh -- both call sites are
# `shell: bash` steps:
#
#     . "$GITHUB_WORKSPACE/.github/scripts/rock-version.sh"
#
# Two deploy guards refuse a deploy whose Rock version does not match what the
# target already runs, both on the minor -- production-deploy.yml against the
# pinned production branch, staging-deploy.yml against the catalog the pr-* fleet
# shares. Both used to read the version themselves, in different
# orders, with different patterns, each commented as the correct one and each
# pinned by a test asserting the opposite of the other. They agreed on this tree
# for one reason: only one of the two files it could read exists. This file is
# the one answer, so a disagreement is no longer something the tree's shape is
# hiding. It also answers which part of the version the guards compare; see
# rock_minor_of_version at the end.

# The probe order, and the whole of what the order decides.
#
# Rock declares its version in one of two places depending on the line. Through
# 18.x it is an assembly attribute in Rock.Version/AssemblySharedInfo.cs:
#
#     [assembly: AssemblyVersion( "18.4.1" )]
#
# Rock 19 deleted that file and moved the version into Directory.Build.props:
#
#     <Version>19.4.4</Version>
#
# A reader that knows only one place cannot compare an 18.x ref against a v19
# branch, which is the comparison both guards exist to make and the one they are
# least dispensable for. So both are consulted and the first that yields a
# version wins.
#
# Props first. The two orders differ only where both files carry a version, and
# the only way that happens here is a 19.x tree that still has an
# AssemblySharedInfo.cs -- which is one plausible build fix away. Rock.Client,
# Rock.Mandrill and CheckScannerUtility still <Compile Include> the deleted file
# on this branch, and pr-test-artifact.yml works around that by excluding the
# project rather than by restoring the file. Restore it and attribute-first reads
# 18.x off a 19.x tree: the production guard then refuses every deploy, and the
# staging guard matches an 18.x pin and waves a 19.x artifact onto the 18.x
# catalog, which is the failure it was written to stop.
#
# The reverse argument, which both readers carried until 2026-09-15, was that
# 18.x ships a Directory.Build.props with no <Version>, so the historical path
# has to be probed first to keep 18.x answering 18.x. The premise is true and the
# conclusion does not follow from it: with no <Version> to find, props-first
# falls through to the attribute and answers 18.x as well. The order was never
# what made that case work, which is why two readers could hold opposite orders
# and both look right.
#
# An array rather than a space-separated string so that a caller iterating it has
# to write "${ROCK_VERSION_FILES[@]}" and cannot quietly get the splitting wrong.
ROCK_VERSION_FILES=(
    "Directory.Build.props"
    "Rock.Version/AssemblySharedInfo.cs"
)

rock_version_of_file() {
    # The version declared in one file, or nothing. Takes any path: production
    # reads a copy it downloaded from another branch under a name of its own.
    #
    # Digits and dots only, anchored on the exact spelling of each declaration.
    # Both formats surround the real version with lines that also contain the
    # word "version" -- AssemblyFileVersion and AssemblyInformationalVersion in
    # the 18.x file, <FileVersion> and <InformationalVersion> in the props -- and
    # <FileVersion>$(Version)</FileVersion> is a real line in Rock 19's props
    # that a looser `<Version>\([^<]*\)` reports as the literal string
    # "$(Version)". A guard comparing that against a minor refuses forever.
    #
    # First match wins, taken with a parameter expansion rather than `| head -1`.
    # This file is sourced into scripts running `set -o pipefail`, where head
    # closing the pipe early can fail the run on sed's SIGPIPE.
    local matches
    matches="$(
        sed -n \
            -e 's:.*<Version>[[:space:]]*\([0-9][0-9.]*\)[[:space:]]*</Version>.*:\1:p' \
            -e 's:.*AssemblyVersion([[:space:]]*"\([0-9][0-9.]*\)"[[:space:]]*).*:\1:p' \
            "$1" 2>/dev/null
    )"
    printf '%s\n' "${matches%%$'\n'*}"
}

rock_version_of_tree() {
    # The version declared by the checkout rooted at $1 (default: the working
    # directory), on stdout. Returns non-zero and prints nothing on stdout when
    # no candidate file yields one -- an unreadable version is a refusal at both
    # call sites, so it must never be mistaken for an empty answer that compares
    # equal to nothing.
    local root="${1:-.}" candidate version

    for candidate in "${ROCK_VERSION_FILES[@]}"; do
        # Test before parsing. Letting sed fail into an empty version reads as
        # "no minor change" on a guard whose whole job is to refuse when it
        # cannot tell.
        [ -f "$root/$candidate" ] || continue
        version="$(rock_version_of_file "$root/$candidate")"
        if [ -n "$version" ]; then
            # Provenance on stderr: the caller takes the version off stdout, and
            # the run log still says which of the two files answered -- the fact
            # you want first when a guard reports a version you did not expect.
            echo "Read Rock $version from $candidate." >&2
            printf '%s\n' "$version"
            return 0
        fi
    done

    echo "::error::Could not read the Rock version from $root (looked in: ${ROCK_VERSION_FILES[*]})." >&2
    return 1
}

rock_version_of_branch() {
    # The Rock version a branch is named for -- 19.4.4 for passion-19.4.4 -- on
    # stdout.
    #
    # The staging guard's pin arrives as a branch name (`baseBranch` in
    # .github/pr-test-environments.json), and that name is the only version it
    # has for the fleet. The guard used to cut the major out of the name with a
    # sed of its own; this hands back the whole version, so the guard takes the
    # minor from both sides through the same function.
    #
    # Only for the passion-<version> trunks, and the whole name or nothing. Other
    # branches here are not named for what they declare -- `develop` is 19.0.3,
    # `staging` is 17.6.1 -- and a suffix such as passion-19.4.4-hotfix is a name
    # the guard would have to guess at. Both refuse the way rock_version_of_tree
    # does. The old sed took a major from anything shaped passion-19.<anything>;
    # every pin this repository has used is a bare passion-<version>.
    #
    # What counts as a version is rock_minor_of_version's to decide, so the name
    # is checked by it rather than by a second pattern here. Its own annotation is
    # dropped: the one below names the branch, which is what the operator has to
    # go and fix.
    local branch="${1:-}"
    local version="${branch#passion-}"

    if [ "$version" != "$branch" ] && rock_minor_of_version "$version" >/dev/null 2>&1; then
        printf '%s\n' "$version"
        return 0
    fi

    echo "::error::Branch '$branch' is not named for a Rock version (expected passion-<version>, such as passion-19.4.4)." >&2
    return 1
}

# The part of a version the guards compare.
#
# A version's **minor** is its major and minor: 19.4 of 19.4.4. Its **line** is
# its major alone: 19. Production has always refused a ref on a different minor
# from the production branch. Staging refused an artifact on a different line
# from the fleet's pin, and allowed 18.4.1 -> 18.5.0, until 2026-10-20, when it
# moved to the minor as well: Rock ships schema migrations in minor releases, so
# a minor bump on a shared catalog is the line change's hazard at a smaller
# size. rock_line_of_version went with the last guard that called it.
#
# Both guards used to read the version through this file and then slice it
# themselves, with `${version%.*}` and `${version%%.*}`, each commented as "the
# minor". One character apart, two different answers, and nothing in either step
# said which it was. Named here so both call the one answer.

rock_minor_of_version() {
    # The minor of the version $1 -- 19.4 for 19.4.4, and for 19.4 -- on stdout.
    #
    # Also the one place that decides what a version looks like: two or three
    # numbers joined by single dots. rock_version_of_file reads [0-9][0-9.]* and so
    # can hand back "19." or "19..4"; the old slices made a minor out of those and
    # the guard compared it. Anything else refuses the way rock_version_of_tree
    # does -- non-zero, nothing on stdout, an annotation on stderr -- because a
    # guard that cannot tell must not compare an empty answer with another one and
    # call them equal.
    #
    # A bare major ("19") is refused, and so are four parts. Neither declaration
    # Rock has used carries either: both are three parts, 18.4.1 and 19.4.4. The
    # four-part shape is the old Rock 1.x numbering, 1.19.4.4, whose first two
    # parts are "1.19" -- a minor that compares with nothing a guard means.
    #
    # The pattern sits in a variable because that is the one spelling of `=~`
    # that every bash from 3.2 onward reads as a regex rather than a literal
    # string. The tests run under macOS's /bin/bash 3.2; the runners have bash 5.
    local version="${1:-}"
    local pattern='^([0-9]+\.[0-9]+)(\.[0-9]+)?$'

    if [[ $version =~ $pattern ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi

    echo "::error::'$version' is not a Rock version (expected two or three numbers joined by dots, such as 19.4.4)." >&2
    return 1
}
