#!/bin/zsh
# Removes only test residue from RevvyTach's local storage. The default is a
# dry run; --apply first copies every target to a timestamped backup directory.

set -euo pipefail

mode="dry-run"
if [[ "${1:-}" == "--apply" ]]; then
    mode="apply"
elif [[ -n "${1:-}" ]]; then
    print -u2 "Usage: $0 [--apply]"
    exit 64
fi

app_support="$HOME/Library/Application Support/RevvyTach"
profile_data="$app_support/profile-data"
preferences="$HOME/Library/Preferences"
domain="com.revenium.RevvyTach"
script_dir="${0:A:h}"
work_dir="${script_dir:h}/.build-artifacts/unit-b-scratch"
/bin/mkdir -p "$work_dir"

domain_export="$work_dir/$domain.plist"
profile_registry_encoded="$work_dir/profiles_v3.base64"
profile_registry="$work_dir/profiles_v3.json"
real_ids="$work_dir/real-profile-ids"
directory_ids="$work_dir/profile-data-directory-ids"
missing_real_ids="$work_dir/missing-real-profile-ids"
targets="$work_dir/targets"

/usr/bin/defaults export "$domain" "$domain_export"
/usr/bin/plutil -extract profiles_v3 raw -o "$profile_registry_encoded" "$domain_export"
/usr/bin/base64 -D -i "$profile_registry_encoded" -o "$profile_registry"
/usr/bin/jq -r '.[].id | ascii_downcase' "$profile_registry" \
    | /usr/bin/sort -u > "$real_ids"

real_id_count="$(/usr/bin/wc -l < "$real_ids" | /usr/bin/tr -d ' ')"
if (( real_id_count == 0 )); then
    print -u2 "Refusing cleanup: profiles_v3 yielded no real profile IDs."
    exit 1
fi

if [[ -d "$profile_data" ]]; then
    /usr/bin/find "$profile_data" -mindepth 1 -maxdepth 1 -type d \
        -exec /usr/bin/basename {} \; \
        | /usr/bin/tr '[:upper:]' '[:lower:]' \
        | /usr/bin/sort -u > "$directory_ids"
else
    : > "$directory_ids"
fi

/usr/bin/comm -23 "$real_ids" "$directory_ids" > "$missing_real_ids"
if [[ -s "$missing_real_ids" ]]; then
    print -u2 "Refusing cleanup: one or more real profile IDs have no directory."
    /usr/bin/sed 's/^/  missing: /' "$missing_real_ids" >&2
    exit 1
fi

: > "$targets"
if [[ -d "$profile_data" ]]; then
    while IFS= read -r -d '' directory; do
        profile_id="${directory:t:l}"
        if ! /usr/bin/grep -Fxq "$profile_id" "$real_ids"; then
            print -r -- "$directory" >> "$targets"
        fi
    done < <(/usr/bin/find "$profile_data" -mindepth 1 -maxdepth 1 -type d -print0)
fi

# These are suite-name prefixes used only by the hosted test target. Keep this
# list narrow: the shipping app's own preference domain is never a target.
for pattern in \
    'LegacyIdentityMigrationServiceTests.*.plist' \
    'ClaudeUsageTests.CurrentUsage.*.plist' \
    'ClaudeUsageTests.ProfileSecurity.*.plist' \
    'test.notification.keys.*.plist' \
    'ClaudeUsageTests.SharedDataStoreTests.*.plist' \
    'ProviderHistoryNotificationTests.*.plist' \
    'UsageHistoryServiceTests.*.plist' \
    'ProfileProviderCoreTests.*.plist' \
    'KeychainOwnershipAdoptionServiceTests.*.plist' \
    'MenuBarOverflowModeTests.*.plist' \
    'ProfileKeychainDomainMigrationServiceTests.*.plist' \
    'LegacyBundleRelocationServiceTests.*.plist' \
    'GitHubServiceContributorCacheTests.*.plist' \
    'StatusItemPositionSanitizerTests.*.plist' \
    'DistributionConfigurationTests.*.plist' \
    'ExtraUsageScopeTests.*.plist'; do
    for preference_file in "$preferences"/$~pattern(N); do
        print -r -- "$preference_file" >> "$targets"
    done
done

directory_count="$(/usr/bin/awk -v root="$profile_data/" 'index($0, root) == 1 { count += 1 } END { print count + 0 }' "$targets")"
preference_count="$(/usr/bin/awk -v root="$preferences/" 'index($0, root) == 1 { count += 1 } END { print count + 0 }' "$targets")"
total_directory_count="$(/usr/bin/wc -l < "$directory_ids" | /usr/bin/tr -d ' ')"
retained_directory_count=$(( total_directory_count - directory_count ))
if (( retained_directory_count != real_id_count )); then
    print -u2 "Refusing cleanup: would retain $retained_directory_count directories for $real_id_count real profile IDs."
    exit 1
fi
print "Would remove $directory_count orphaned profile-data directories and $preference_count test preference files."
/usr/bin/sed 's/^/  /' "$targets"

if [[ "$mode" == "dry-run" ]]; then
    print "Dry run only; nothing was changed. Re-run with --apply to back up and remove these targets."
    exit 0
fi

backup_root="$app_support/test-storage-litter-backups/$(/bin/date +%Y%m%d-%H%M%S)"
/bin/mkdir -p "$backup_root/profile-data" "$backup_root/preferences"
while IFS= read -r target; do
    if [[ "$target" == "$profile_data/"* ]]; then
        /bin/cp -pR "$target" "$backup_root/profile-data/"
    else
        /bin/cp -p "$target" "$backup_root/preferences/"
    fi
done < "$targets"
print "Backup created at $backup_root"

while IFS= read -r target; do
    /bin/rm -rf "$target"
done < "$targets"
print "Removed $directory_count orphaned profile-data directories and $preference_count test preference files."
