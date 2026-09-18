#!/usr/bin/env bash
set -euo pipefail

readonly ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly ACCOUNT_ID="b23961d27a30fd566f13f90671b98cc5"
readonly ZONE_ID="041787ceb139b0e5b3e93a627c9e14e7"
readonly API="https://api.cloudflare.com/client/v4"
readonly TUNNEL_NAME="homelab-public"
readonly PUBLIC_HOSTNAME="*.3rr.dev"
readonly TUNNEL_ORIGIN="http://cilium-gateway-public.gateway-system.svc.cluster.local:80"
readonly TOKEN_FILE="${CF_API_TOKEN_FILE:-/home/j/cf_better_token}"
readonly SECRET_FILE="$ROOT/kubernetes/platform/networking/public-edge/secrets/cloudflared.yaml"
readonly AGE_RECIPIENT="age1sjrw9cudya5fhnucvlhqsrfpv8g6zn56tvffx3ns5rr935z3v3aq7hydlz"
readonly GEO_RULE_DESCRIPTION="Public edge: block traffic outside EU and US"
readonly SOURCE_RULE_DESCRIPTION="Public edge: block non-allowlisted source IPs"
readonly OLD_SOURCE_RULE_DESCRIPTION="Public isolation PoC: block non-allowlisted source IPs"
readonly RATE_LIMIT_DESCRIPTION="Public edge: block rapid Pocket ID passkey requests"
readonly OLD_RATE_LIMIT_DESCRIPTION="Public edge: block rapid login requests"
readonly MANAGED_WAF_DESCRIPTION="Public edge: execute Cloudflare Free Managed Ruleset"
readonly ALLOWED_COUNTRY_SET='{"AT" "BE" "BG" "HR" "CY" "CZ" "DK" "EE" "FI" "FR" "DE" "GR" "HU" "IE" "IT" "LV" "LT" "LU" "MT" "NL" "PL" "PT" "RO" "SK" "SI" "ES" "SE" "US"}'

if [[ ! -s $TOKEN_FILE ]]; then
  echo "Cloudflare API token file is missing or empty: $TOKEN_FILE" >&2
  exit 1
fi
IFS= read -r CF_API_TOKEN < "$TOKEN_FILE"
export CF_API_TOKEN

api() {
  curl -sS --retry 3 \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json" \
    "$@"
}

require_success() {
  local action=$1 response=$2
  if ! jq -e '.success == true' >/dev/null <<<"$response"; then
    echo "Cloudflare API failed while $action:" >&2
    jq '{errors, messages}' <<<"$response" >&2
    exit 1
  fi
}

get_tunnel() {
  local response
  response=$(api --get "$API/accounts/$ACCOUNT_ID/cfd_tunnel" \
    --data-urlencode "name=$TUNNEL_NAME" \
    --data-urlencode "is_deleted=false")
  require_success "looking up the production tunnel" "$response"
  if [[ $(jq '.result | length' <<<"$response") != 1 ]]; then
    return 1
  fi
  jq -c '.result[0]' <<<"$response"
}

geographic_expression() {
  printf '((http.host eq "3rr.dev" or ends_with(http.host, ".3rr.dev")) and not (ip.src.country in %s))' \
    "$ALLOWED_COUNTRY_SET"
}

configure_rate_limit() {
  local rulesets phase_rulesets ruleset_id ruleset rules matching rule_id
  local rule_payload ruleset_payload response

  rulesets=$(api "$API/zones/$ZONE_ID/rulesets")
  require_success "listing zone rulesets for rate limiting" "$rulesets"
  phase_rulesets=$(jq '[.result[] | select(.phase == "http_ratelimit" and .kind == "zone")]' <<<"$rulesets")
  if (( $(jq 'length' <<<"$phase_rulesets") > 1 )); then
    echo "Multiple zone rate-limit entry points exist; refusing to choose one." >&2
    exit 1
  fi

  # The Free plan permits one rule with a 10-second counting period. Spend it
  # on Pocket ID's actual passkey exchange. A successful login uses start and
  # finish, so ten requests still permit several legitimate retries.
  rule_payload=$(jq -nc --arg description "$RATE_LIMIT_DESCRIPTION" '{
    action:"block",
    description:$description,
    expression:"(starts_with(http.request.uri.path, \"/api/webauthn/login/\"))",
    ratelimit:{
      characteristics:["cf.colo.id","ip.src"],
      period:10,
      requests_per_period:10,
      mitigation_timeout:10
    },
    enabled:true
  }')

  if [[ $(jq 'length' <<<"$phase_rulesets") == 0 ]]; then
    ruleset_payload=$(jq -nc --argjson rule "$rule_payload" '{
      name:"default",
      description:"Zone-level login abuse protection",
      kind:"zone",
      phase:"http_ratelimit",
      rules:[$rule]
    }')
    response=$(api -X POST "$API/zones/$ZONE_ID/rulesets" --data "$ruleset_payload")
    require_success "creating the zone login rate limit" "$response"
    echo "Login rate limiting is configured."
    return
  fi

  ruleset_id=$(jq -r '.[0].id' <<<"$phase_rulesets")
  ruleset=$(api "$API/zones/$ZONE_ID/rulesets/$ruleset_id")
  require_success "reading the zone rate-limit entry point" "$ruleset"
  rules=$(jq '.result.rules // []' <<<"$ruleset")
  matching=$(jq --arg description "$RATE_LIMIT_DESCRIPTION" --arg old "$OLD_RATE_LIMIT_DESCRIPTION" \
    '[.[] | select(.description == $description or .description == $old)]' <<<"$rules")
  if (( $(jq 'length' <<<"$matching") > 1 )); then
    echo "Multiple managed login rate-limit rules exist; refusing to update them." >&2
    exit 1
  fi
  if [[ $(jq 'length' <<<"$matching") == 1 ]]; then
    rule_id=$(jq -r '.[0].id' <<<"$matching")
    response=$(api -X PATCH "$API/zones/$ZONE_ID/rulesets/$ruleset_id/rules/$rule_id" \
      --data "$rule_payload")
  elif [[ $(jq 'length' <<<"$rules") == 0 ]]; then
    response=$(api -X POST "$API/zones/$ZONE_ID/rulesets/$ruleset_id/rules" \
      --data "$rule_payload")
  else
    echo "The Free-plan rate-limit slot is owned by an unmanaged rule; refusing to replace it." >&2
    exit 1
  fi
  require_success "configuring the zone login rate limit" "$response"
  echo "Login rate limiting is configured."
}

configure_geographic_waf() {
  local ruleset rules geo_matching legacy_matching rule_id expression
  local waf_payload waf_response delete_response
  ruleset=$(api "$API/zones/$ZONE_ID/rulesets/phases/http_request_firewall_custom/entrypoint")
  require_success "reading the zone WAF entry point" "$ruleset"
  rules=$(jq '.result.rules // []' <<<"$ruleset")
  geo_matching=$(jq --arg description "$GEO_RULE_DESCRIPTION" \
    '[.[] | select(.description == $description)]' <<<"$rules")
  legacy_matching=$(jq --arg current "$SOURCE_RULE_DESCRIPTION" --arg old "$OLD_SOURCE_RULE_DESCRIPTION" \
    '[.[] | select(.description == $current or .description == $old)]' <<<"$rules")
  if (( $(jq 'length' <<<"$geo_matching") > 1 || $(jq 'length' <<<"$legacy_matching") > 1 )); then
    echo "Multiple managed geographic or legacy source-IP WAF rules exist; refusing to choose." >&2
    exit 1
  fi
  expression=$(geographic_expression)
  waf_payload=$(jq -nc --arg description "$GEO_RULE_DESCRIPTION" --arg expression "$expression" \
    '{action:"block",description:$description,expression:$expression,enabled:true}')
  if [[ $(jq 'length' <<<"$geo_matching") == 1 ]]; then
    rule_id=$(jq -r '.[0].id' <<<"$geo_matching")
    waf_response=$(api -X PATCH "$API/zones/$ZONE_ID/rulesets/$(jq -r '.result.id' <<<"$ruleset")/rules/$rule_id" \
      --data "$waf_payload")
  else
    waf_response=$(api -X POST "$API/zones/$ZONE_ID/rulesets/$(jq -r '.result.id' <<<"$ruleset")/rules" \
      --data "$waf_payload")
  fi
  require_success "installing the EU and US geographic WAF rule" "$waf_response"

  # Create and verify the broader steady-state rule before removing the old
  # source-IP gate, so there is no unprotected transition window.
  if [[ $(jq 'length' <<<"$legacy_matching") == 1 ]]; then
    rule_id=$(jq -r '.[0].id' <<<"$legacy_matching")
    delete_response=$(api -X DELETE "$API/zones/$ZONE_ID/rulesets/$(jq -r '.result.id' <<<"$ruleset")/rules/$rule_id")
    require_success "removing the legacy source-IP WAF rule" "$delete_response"
  fi
  echo "WAF now limits 3rr.dev to EU member states and the United States."
}

configure_managed_waf() {
  local rulesets managed matching_entry entry_id entry rules execute_rules
  local matching_rule rule_id payload ruleset_payload response
  rulesets=$(api "$API/zones/$ZONE_ID/rulesets")
  require_success "listing zone rulesets for managed WAF" "$rulesets"
  managed=$(jq '[.result[] | select(.kind == "managed" and .phase == "http_request_firewall_managed" and .name == "Cloudflare Managed Free Ruleset")]' <<<"$rulesets")
  if [[ $(jq 'length' <<<"$managed") != 1 ]]; then
    echo "Expected exactly one Cloudflare Managed Free Ruleset; refusing to guess." >&2
    exit 1
  fi
  matching_entry=$(jq '[.result[] | select(.kind == "zone" and .phase == "http_request_firewall_managed")]' <<<"$rulesets")
  if (( $(jq 'length' <<<"$matching_entry") > 1 )); then
    echo "Multiple managed-WAF entry points exist; refusing to choose one." >&2
    exit 1
  fi
  payload=$(jq -nc --arg description "$MANAGED_WAF_DESCRIPTION" --arg id "$(jq -r '.[0].id' <<<"$managed")" \
    '{action:"execute",action_parameters:{id:$id},expression:"true",description:$description,enabled:true}')
  if [[ $(jq 'length' <<<"$matching_entry") == 0 ]]; then
    ruleset_payload=$(jq -nc --argjson rule "$payload" '{name:"default",description:"Zone-level managed WAF",kind:"zone",phase:"http_request_firewall_managed",rules:[$rule]}')
    response=$(api -X POST "$API/zones/$ZONE_ID/rulesets" --data "$ruleset_payload")
    require_success "deploying the Cloudflare Managed Free Ruleset" "$response"
    echo "Cloudflare Managed Free Ruleset is deployed."
    return
  fi
  entry_id=$(jq -r '.[0].id' <<<"$matching_entry")
  entry=$(api "$API/zones/$ZONE_ID/rulesets/$entry_id")
  require_success "reading the managed-WAF entry point" "$entry"
  rules=$(jq '.result.rules // []' <<<"$entry")
  matching_rule=$(jq --arg description "$MANAGED_WAF_DESCRIPTION" '[.[] | select(.description == $description)]' <<<"$rules")
  execute_rules=$(jq '[.[] | select(.action == "execute")]' <<<"$rules")
  if (( $(jq 'length' <<<"$matching_rule") > 1 )); then
    echo "Multiple managed Free WAF deployment rules exist; refusing to update them." >&2
    exit 1
  fi
  if [[ $(jq 'length' <<<"$matching_rule") == 1 ]]; then
    rule_id=$(jq -r '.[0].id' <<<"$matching_rule")
    response=$(api -X PATCH "$API/zones/$ZONE_ID/rulesets/$entry_id/rules/$rule_id" --data "$payload")
  elif [[ $(jq 'length' <<<"$execute_rules") == 0 ]]; then
    response=$(api -X POST "$API/zones/$ZONE_ID/rulesets/$entry_id/rules" --data "$payload")
  else
    echo "An unmanaged managed-WAF deployment already exists; refusing to replace it." >&2
    exit 1
  fi
  require_success "deploying the Cloudflare Managed Free Ruleset" "$response"
  echo "Cloudflare Managed Free Ruleset is deployed."
}

configure_zone_security() {
  local response
  response=$(api -X PATCH "$API/zones/$ZONE_ID/settings/min_tls_version" --data '{"value":"1.2"}')
  require_success "setting the minimum TLS version to 1.2" "$response"
  echo "Cloudflare minimum TLS version is 1.2."
}

configure_edge_hardening() {
  configure_geographic_waf
  configure_managed_waf
  configure_rate_limit
  configure_zone_security
}

prepare() {
  local tunnels tunnel tunnel_id config token_response tunnel_token

  tunnels=$(api --get "$API/accounts/$ACCOUNT_ID/cfd_tunnel" \
    --data-urlencode "name=$TUNNEL_NAME" \
    --data-urlencode "is_deleted=false")
  require_success "looking up the production tunnel" "$tunnels"
  case $(jq '.result | length' <<<"$tunnels") in
    0)
      tunnel=$(api -X POST "$API/accounts/$ACCOUNT_ID/cfd_tunnel" \
        --data "$(jq -nc --arg name "$TUNNEL_NAME" '{name:$name, config_src:"cloudflare"}')")
      require_success "creating the production tunnel" "$tunnel"
      ;;
    1)
      tunnel=$(jq -c '{success:true,result:.[0]}' <<<"$(jq '.result' <<<"$tunnels")")
      ;;
    *)
      echo "Multiple active tunnels named $TUNNEL_NAME; refusing to choose one." >&2
      exit 1
      ;;
  esac
  tunnel_id=$(jq -r '.result.id' <<<"$tunnel")

  config=$(api -X PUT "$API/accounts/$ACCOUNT_ID/cfd_tunnel/$tunnel_id/configurations" \
    --data "$(jq -nc --arg hostname "$PUBLIC_HOSTNAME" --arg service "$TUNNEL_ORIGIN" \
      '{config:{ingress:[{hostname:$hostname,service:$service,originRequest:{}},{service:"http_status:404"}],"warp-routing":{enabled:false}}}')")
  require_success "configuring the production tunnel ingress" "$config"

  token_response=$(api "$API/accounts/$ACCOUNT_ID/cfd_tunnel/$tunnel_id/token")
  require_success "obtaining the production tunnel token" "$token_response"
  tunnel_token=$(jq -r '.result' <<<"$token_response")
  if [[ -z $tunnel_token || $tunnel_token == null ]]; then
    echo "Cloudflare returned an empty tunnel token." >&2
    exit 1
  fi

  local plain_secret
  plain_secret=$(mktemp)
  trap 'truncate -s 0 "$plain_secret" 2>/dev/null || true; rm -f -- "$plain_secret"' EXIT
  TUNNEL_TOKEN=$tunnel_token yq -n '
    .apiVersion = "isindir.github.com/v1alpha3" |
    .kind = "SopsSecret" |
    .metadata.name = "cloudflared" |
    .metadata.namespace = "cloudflare-tunnel" |
    .spec.secretTemplates = [{"name":"cloudflared-token","stringData":{"token":strenv(TUNNEL_TOKEN)}}]
  ' >"$plain_secret"
  sops --encrypt --input-type yaml --output-type yaml --age "$AGE_RECIPIENT" \
    --encrypted-regex '^(data|stringData)$' \
    --output "$SECRET_FILE" "$plain_secret"
  truncate -s 0 "$plain_secret"
  rm -f -- "$plain_secret"
  trap - EXIT
  unset tunnel_token TUNNEL_TOKEN

  configure_edge_hardening

  echo "Prepared tunnel $TUNNEL_NAME and encrypted its connector token."
  echo "WAF now blocks 3rr.dev traffic outside the EU and United States."
  echo "DNS is unchanged; run '$0 publish' only after cluster verification passes."
}

publish() {
  local tunnel tunnel_id tunnel_status ruleset matching expected_expression records count record_id response
  tunnel=$(get_tunnel) || {
    echo "Expected exactly one active tunnel named $TUNNEL_NAME." >&2
    exit 1
  }
  tunnel_id=$(jq -r '.id' <<<"$tunnel")
  tunnel_status=$(jq -r '.status' <<<"$tunnel")
  if [[ $tunnel_status != healthy || $(jq '.connections | length' <<<"$tunnel") == 0 ]]; then
    echo "Tunnel is not healthy with an active connector; refusing DNS publication." >&2
    exit 1
  fi

  ruleset=$(api "$API/zones/$ZONE_ID/rulesets/phases/http_request_firewall_custom/entrypoint")
  require_success "checking the WAF before publication" "$ruleset"
  expected_expression=$(geographic_expression)
  matching=$(jq --arg description "$GEO_RULE_DESCRIPTION" --arg expression "$expected_expression" \
    '[.result.rules[] | select(.description == $description and .enabled == true and .expression == $expression)]' <<<"$ruleset")
  if [[ $(jq 'length' <<<"$matching") != 1 ]]; then
    echo "The enabled EU and US geographic WAF rule is missing or drifted; refusing DNS publication." >&2
    exit 1
  fi

  records=$(api --get "$API/zones/$ZONE_ID/dns_records" --data-urlencode "name=$PUBLIC_HOSTNAME")
  require_success "checking wildcard DNS" "$records"
  count=$(jq '.result | length' <<<"$records")
  if (( count == 0 )); then
    response=$(api -X POST "$API/zones/$ZONE_ID/dns_records" --data "$(jq -nc \
      --arg name "$PUBLIC_HOSTNAME" --arg content "$tunnel_id.cfargotunnel.com" \
      '{type:"CNAME",name:$name,content:$content,proxied:true,ttl:1}')")
    require_success "publishing wildcard DNS" "$response"
  elif (( count == 1 )); then
    record_id=$(jq -r '.result[0].id' <<<"$records")
    if [[ $(jq -r '.result[0].type' <<<"$records") != CNAME || \
          $(jq -r '.result[0].content' <<<"$records") != "$tunnel_id.cfargotunnel.com" ]]; then
      echo "Wildcard DNS is owned by another target; refusing to overwrite it." >&2
      exit 1
    fi
    response=$(api -X PATCH "$API/zones/$ZONE_ID/dns_records/$record_id" \
      --data '{"proxied":true,"ttl":1}')
    require_success "ensuring wildcard DNS is proxied" "$response"
  else
    echo "Multiple wildcard DNS records exist; refusing publication." >&2
    exit 1
  fi
  echo "Published $PUBLIC_HOSTNAME through healthy tunnel $TUNNEL_NAME."
}

disable() {
  local tunnel tunnel_id records record_id response
  tunnel=$(get_tunnel) || {
    echo "Production tunnel is absent; nothing to disable."
    return
  }
  tunnel_id=$(jq -r '.id' <<<"$tunnel")
  records=$(api --get "$API/zones/$ZONE_ID/dns_records" --data-urlencode "name=$PUBLIC_HOSTNAME")
  require_success "checking wildcard DNS" "$records"
  if [[ $(jq '.result | length' <<<"$records") == 0 ]]; then
    echo "$PUBLIC_HOSTNAME is already absent."
    return
  fi
  if [[ $(jq '.result | length' <<<"$records") != 1 || \
        $(jq -r '.result[0].type' <<<"$records") != CNAME || \
        $(jq -r '.result[0].content' <<<"$records") != "$tunnel_id.cfargotunnel.com" ]]; then
    echo "Wildcard DNS is not uniquely owned by $TUNNEL_NAME; refusing deletion." >&2
    exit 1
  fi
  record_id=$(jq -r '.result[0].id' <<<"$records")
  response=$(api -X DELETE "$API/zones/$ZONE_ID/dns_records/$record_id")
  require_success "removing wildcard DNS" "$response"
  echo "Removed $PUBLIC_HOSTNAME; the connector and WAF remain configured."
}

case ${1:-} in
  prepare) prepare ;;
  harden|waf) configure_edge_hardening ;;
  rate-limit) configure_rate_limit ;;
  publish) publish ;;
  disable) disable ;;
  *) echo "usage: $0 prepare|harden|waf|rate-limit|publish|disable" >&2; exit 2 ;;
esac
