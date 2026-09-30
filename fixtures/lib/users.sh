#!/usr/bin/env bash
# A user database, under the prefix, for the identity fakes to write and weedr
# to read back.
#
# weedr's read-back is the point of ADR-0003's rule: `useradd` succeeding is the
# tool's word for it and `/etc/passwd` holding the entry is the fact. A fake that
# logged the call and modelled nothing would make that read-back untestable, and
# the read-back is the step that catches a service whose containers could not
# map their own root.

set -u

# users: uid allocation. The first free system-ish uid at or above 1000, so two
# services in one test get two different ones and a firewall rule naming a uid
# means something.
: "${GUARDEN_USERS_BASE:=1000}"

passwd_file="${GUARDEN_PREFIX:-}/etc/passwd"
subuid_file="${GUARDEN_PREFIX:-}/etc/subuid"
subgid_file="${GUARDEN_PREFIX:-}/etc/subgid"

_next_uid() {
    local highest=$((GUARDEN_USERS_BASE - 1))
    local line
    if [ -f "$passwd_file" ]; then
        while IFS= read -r line; do
            local uid
            uid=$(printf '%s' "$line" | cut -d: -f3)
            case "$uid" in
                ''|*[!0-9]*) continue ;;
            esac
            [ "$uid" -gt "$highest" ] && highest=$uid
        done <"$passwd_file"
    fi
    printf '%s' "$((highest + 1))"
}

# fake_user_write <name> <uid> <shell>: the passwd entry, the shadow entry, and
# the home. The shell is the one that was asked for, so a caller that gave the
# user a login shell would be caught here rather than in production.
fake_user_write() {
    local name=$1 uid=$2 shell=${3:-/usr/sbin/nologin}
    printf '%s:x:%s:%s::%s:%s\n' \
        "$name" "$uid" "$uid" "/var/lib/guarden/services/$name/home" "$shell" >>"$passwd_file"
    mkdir -p "${GUARDEN_PREFIX:-}/var/lib/guarden/services/$name/home" 2>/dev/null || true
}

# fake_user_known <name>
fake_user_known() {
    local name=$1 line
    [ -f "$passwd_file" ] || return 1
    while IFS= read -r line; do
        [ "${line%%:*}" = "$name" ] && return 0
    done <"$passwd_file"
    return 1
}

# fake_subid_base <size>: the first free block at the system's base, which is
# what the shadow tools do and what makes one hardcoded range for every service
# impossible — `100000:65536` for everyone maps every container's root to the
# same host uid, and the firewall's uid matching stops meaning what it says.
fake_subid_base() {
    local size=$1
    local start=100000
    while fake_subid_taken "$subuid_file" "$start" "$size"; do
        start=$((start + size))
    done
    printf '%s' "$start"
}

fake_subid_taken() {
    local file=$1 start=$2 size=$3
    local line first count
    [ -f "$file" ] || return 1
    while IFS= read -r line; do
        first=$(printf '%s' "$line" | cut -d: -f2)
        count=$(printf '%s' "$line" | cut -d: -f3)
        case "$first$count" in
            ''|*[!0-9]*) continue ;;
        esac
        if [ "$start" -ge "$first" ] && [ "$start" -lt $((first + count)) ]; then
            return 0
        fi
    done <"$file"
    return 1
}

# fake_subid_write <file> <name> <first> <count>
#
# A marker in the fixture state makes the allocation silently not happen, which
# is the failure weedr's read-back exists to catch: a service whose range was
# never written gets a container that starts and then cannot map its own root.
fake_subid_write() {
    local file=$1 name=$2 first=$3 count=$4
    [ -e "$GUARDEN_FIXTURES/subid-unallocated" ] && return 0
    printf '%s:%s:%s\n' "$name" "$first" "$count" >>"$file"
}
