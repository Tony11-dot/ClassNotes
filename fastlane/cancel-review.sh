#!/bin/bash
# Withdraws the ClassNotes build that is waiting for (or in) App Store review and
# waits until its version unlocks, so `fastlane ios submit` can attach a newer
# build. deliver can't do this itself: it doesn't treat a version in review as
# editable, tries to create a new one, and fails.
#
#   fastlane/cancel-review.sh            cancel, then wait for the unlock
#   fastlane/cancel-review.sh --status   print the real review state, change nothing
#
# `--status` exists because the `check` lane misreports a version in review: the
# "edit version" lookup it uses skips that state and shows the live one instead.
#
# Kept to this single job on purpose — the owner allows exactly this command.
set -euo pipefail

FASTLANE_LIBEXEC=/opt/homebrew/opt/fastlane/libexec
GEMS="${FASTLANE_GEM_HOME:-$HOME/.local/share/fastlane/4.0.0}"

GEM_HOME="$GEMS" GEM_PATH="$GEMS:$FASTLANE_LIBEXEC" \
  exec /opt/homebrew/opt/ruby/bin/ruby - "$@" <<'RUBY'
require "spaceship"

# ClassNotes' own key, same as the Fastfile's default. Not ASC_KEY_PATH: ~/.zshrc
# points that at ClassMate's key.
Spaceship::ConnectAPI.token = Spaceship::ConnectAPI::Token.create(
  key_id: "Z5KM7D8NG8",
  issuer_id: "51a27d98-8621-4258-a919-f335d14ba3f8",
  filepath: File.expand_path("~/Documents/ClassMate docs/ClassNotes/AuthKey_Z5KM7D8NG8.p8")
)
app = Spaceship::ConnectAPI::App.find("com.classmate.notes") or abort "ClassNotes not found on App Store Connect."

def newest_version(app)
  v = app.get_app_store_versions(includes: "build").first
  "#{v.version_string} (#{v.build&.version || "no build"}): #{v.app_store_state}"
end

open = app.get_review_submissions(filter: { state: "WAITING_FOR_REVIEW,IN_REVIEW,UNRESOLVED_ISSUES" })

if ARGV.first == "--status"
  puts newest_version(app)
  open.each { |s| puts "Submission #{s.id}: #{s.state}" }
  exit 0
end

if open.empty?
  puts "Nothing is in review. #{newest_version(app)}"
  exit 0
end

open.each do |s|
  s.cancel_submission
  puts "Cancelled submission #{s.id} (was #{s.state})."
end

# Usually seconds; give it three minutes before calling it stuck.
unlocked = %w[DEVELOPER_REJECTED REJECTED METADATA_REJECTED PREPARE_FOR_SUBMISSION]
last = nil
36.times do
  v = app.get_app_store_versions.first
  state = v.app_store_state
  puts "#{v.version_string}: #{state}" unless state == last
  exit 0 if unlocked.include?(state)
  last = state
  sleep 5
end
abort "The version hasn't unlocked after 3 minutes. Check App Store Connect before submitting."
RUBY
