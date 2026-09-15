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
readonly RULE_DESCRIPTION="Public edge: block non-allowlisted source IPs"
readonly OLD_RULE_DESCRIPTION="Public isolation PoC: block non-allowlisted source IPs"

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

prepare() {
  local public_ip tunnels tunnel tunnel_id config token_response tunnel_token
  public_ip=$(curl -4fsS --max-time 10 https://api.ipify.org)
  if [[ ! $public_ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "Could not determine a valid public IPv4 address; refusing WAF setup." >&2
    exit 1
  fi

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

  local ruleset rules matching rule_id waf_payload waf_response
  ruleset=$(api "$API/zones/$ZONE_ID/rulesets/phases/http_request_firewall_custom/entrypoint")
  require_success "reading the zone WAF entry point" "$ruleset"
  rules=$(jq '.result.rules // []' <<<"$ruleset")
  matching=$(jq --arg current "$RULE_DESCRIPTION" --arg old "$OLD_RULE_DESCRIPTION" \
    '[.[] | select(.description == $current or .description == $old)]' <<<"$rules")
  if (( $(jq 'length' <<<"$matching") > 1 )); then
    echo "Multiple managed source-IP WAF rules exist; refusing to update them." >&2
    exit 1
  fi
  waf_payload=$(jq -nc --arg description "$RULE_DESCRIPTION" --arg ip "$public_ip" '{
    action:"block",
    description:$description,
    expression:("((http.host eq \"3rr.dev\" or ends_with(http.host, \".3rr.dev\")) and ip.src ne " + $ip + ")"),
    enabled:true
  }')
  if [[ $(jq 'length' <<<"$matching") == 1 ]]; then
    rule_id=$(jq -r '.[0].id' <<<"$matching")
    waf_response=$(api -X PATCH "$API/zones/$ZONE_ID/rulesets/$(jq -r '.result.id' <<<"$ruleset")/rules/$rule_id" \
      --data "$waf_payload")
  else
    waf_response=$(api -X POST "$API/zones/$ZONE_ID/rulesets/$(jq -r '.result.id' <<<"$ruleset")/rules" \
      --data "$waf_payload")
  fi
  require_success "installing the source-IP WAF rule" "$waf_response"

  echo "Prepared tunnel $TUNNEL_NAME and encrypted its connector token."
  echo "WAF now blocks 3rr.dev traffic outside public IPv4 $public_ip."
  echo "DNS is unchanged; run '$0 publish' only after cluster verification passes."
}

publish() {
  local tunnel tunnel_id tunnel_status ruleset matching expression expected_ip records count record_id response
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

  expected_ip=$(curl -4fsS --max-time 10 https://api.ipify.org)
  ruleset=$(api "$API/zones/$ZONE_ID/rulesets/phases/http_request_firewall_custom/entrypoint")
  require_success "checking the WAF before publication" "$ruleset"
  matching=$(jq --arg description "$RULE_DESCRIPTION" '[.result.rules[] | select(.description == $description and .enabled == true)]' <<<"$ruleset")
  expression=$(jq -r 'if length == 1 then .[0].expression else "" end' <<<"$matching")
  if [[ $expression != *"ip.src ne $expected_ip"* ]]; then
    echo "The enabled WAF rule does not match current public IPv4 $expected_ip; refusing DNS publication." >&2
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
  publish) publish ;;
  disable) disable ;;
  *) echo "usage: $0 prepare|publish|disable" >&2; exit 2 ;;
esac
