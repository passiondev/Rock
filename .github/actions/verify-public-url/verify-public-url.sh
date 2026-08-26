#!/usr/bin/env bash
#
# Probe a deployed environment's public hostname and report its certificate.
# Reachability failures are fatal. Certificate findings are not.
#
# This is a script rather than bash inlined into action.yml so that something can
# run it. Sixty-four lines lived in the YAML, where the only reader was a runner
# on a live deploy: the self-signed comparison below is there because three
# different printed forms of a DN were observed while it was written, and no test
# could reach the branch that decides between them. It can now, with a stub curl
# and openssl on PATH -- see Tests/PrTestEnvironments/test_verify_public_url.py.
# It is also shellcheck-able where a YAML string was not.
#
# Inputs arrive as environment variables, set by action.yml from its declared
# inputs: HOST_NAME, ATTEMPTS, RETRY_DELAY_SECONDS, REQUEST_TIMEOUT_SECONDS,
# CERTIFICATE_WARNING_DAYS.

set -uo pipefail
url="https://${HOST_NAME}/"

# -k, then report the certificate separately below. Reachability and
# trust are different failures with different owners, and folding them
# together means a certificate that needs renewing reads as an outage.
code=""
for attempt in $(seq 1 "$ATTEMPTS"); do
  code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time "$REQUEST_TIMEOUT_SECONDS" "$url" || echo 000)"
  if [ "$code" != "000" ] && [ "$code" -lt 400 ]; then break; fi
  echo "attempt $attempt: HTTP $code"
  sleep "$RETRY_DELAY_SECONDS"
done

if [ "$code" = "000" ] || [ "$code" -ge 400 ]; then
  echo "::error::$url is not reachable from the internet (last response: HTTP $code), even though the VM reported the deploy healthy. The application started; something between the internet and IIS did not."
  exit 1
fi
echo "$url returned HTTP $code from the runner."

# Never fatal. A self-signed certificate serves traffic perfectly well
# and a browser warning is not a failed deploy -- but it is the thing
# everyone will ask about, so state it plainly rather than leaving it
# to be discovered in the meeting.
#
# Self-signed is decided by issuer == subject, not by pattern-matching a
# CN, because the printed form of a DN is not stable: depending on the
# OpenSSL build and how the name is dumped it comes out as
# "/CN=*.example" (slash-prefixed oneline), "CN=*.example", or
# "CN = *.example" with spaces. All three were observed while building
# this. A grep for any one literal silently matches nothing on the
# others, and a check that can only fail closed is worse than none --
# it reports "certificate fine" for every certificate. Comparing the
# two strings to each other needs no format at all.
cert="$(echo | openssl s_client -connect "${HOST_NAME}:443" -servername "${HOST_NAME}" 2>/dev/null || true)"
issuer="$(printf '%s' "$cert"  | openssl x509 -noout -issuer  2>/dev/null | sed 's/^issuer=//'  || true)"
subject="$(printf '%s' "$cert" | openssl x509 -noout -subject 2>/dev/null | sed 's/^subject=//' || true)"
expiry="$(printf '%s' "$cert"  | openssl x509 -noout -enddate 2>/dev/null | sed 's/^notAfter=//' || true)"

echo "Certificate issuer:  ${issuer:-(could not be read)}"
echo "Certificate subject: ${subject:-(could not be read)}"
echo "Certificate expires: ${expiry:-(could not be read)}"

days_left=""
if [ -n "$expiry" ]; then
  end_epoch="$(date -u -d "$expiry" +%s 2>/dev/null || true)"
  if [ -n "$end_epoch" ]; then
    days_left="$(( (end_epoch - $(date -u +%s)) / 86400 ))"
    echo "Certificate has ${days_left} days remaining."
    if [ "$days_left" -lt "$CERTIFICATE_WARNING_DAYS" ]; then
      echo "::warning::The certificate for $HOST_NAME expires in ${days_left} days. Run the certificate renewal workflow."
    fi
  fi
fi

if [ -n "$issuer" ] && [ "$issuer" = "$subject" ]; then
  echo "::warning::$HOST_NAME is presenting a self-signed certificate, so browsers will show a warning before the site loads. Issuer and subject are both: ${issuer}"
fi

{
  echo "| Public URL | HTTP $code from the GitHub runner |"
  echo "| Certificate | ${issuer:-unknown} |"
  echo "| Expires | ${expiry:-unknown}${days_left:+ (${days_left} days) }|"
} >> "$GITHUB_STEP_SUMMARY"
