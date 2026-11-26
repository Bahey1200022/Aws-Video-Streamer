# CloudFront + AWS WAF

The website is served through **CloudFront** (AWS's CDN), and every web
request is checked by **AWS WAF** at CloudFront before it reaches the frontend.
Code: [terraform/waf.tf](../terraform/waf.tf). Switch: `waf` in
`terraform.tfvars`.

```
viewer ──HTTPS──▶ CloudFront edge + WAF ──HTTPS──▶ frontend nginx (EC2)
phone  ──UDP 51820 (WireGuard) / UDP 8189 (WebRTC media)──────▶ frontend (direct)
```

AWS WAF can't be attached to an EC2 instance, only to CloudFront, a load
balancer or API Gateway. A load balancer needs public subnets in two
Availability Zones (we have one), so CloudFront it is.

## Modes (`waf`)

| Value | Effect |
|---|---|
| `count` (default) | Rules only **log** what they would have blocked. Start here |
| `block` | Matching requests get **403** |
| `off` | No CloudFront: the site's name points straight at the frontend, as before |

It needs `domain_name` and `enable_tls`; without them `waf` is ignored.

## Rules

| Priority | Rule | What it stops |
|---|---|---|
| 10 | `AWSManagedRulesAmazonIpReputationList` | Addresses AWS has seen attacking (botnets, scanners) |
| 20 | Rate limit on `/phone/*` | More than 100 WebRTC handshakes in 5 minutes from one IP (password guessing) |
| 30 | Rate limit on everything | More than 3000 requests in 5 minutes from one IP (~10 viewers behind one address) |
| 40 | `AWSManagedRulesCommonRuleSet` | OWASP-style attacks: XSS, path traversal, file inclusion, SSRF. Its 8 KB body limit only counts (WebRTC offers can be bigger; nginx caps them at 64 KB) |
| 50 | `AWSManagedRulesKnownBadInputsRuleSet` | Known exploit payloads (Log4Shell...) |

## What changed around it

- **Two DNS names.** `bahey.devops.gin-telecom.ovh` now points at CloudFront.
  `bahey-direct.devops.gin-telecom.ovh` always points at the frontend's IP:
  it is CloudFront's origin and the phone's WireGuard endpoint (CloudFront
  only carries HTTP). **After the first apply, re-import the phone's
  WireGuard config** (`ansible/phone/mss-phone.conf` / QR code): its endpoint
  changed.
- **Ports 80/443 only accept CloudFront.** They use AWS's managed list of
  CloudFront addresses. That list counts as ~52 rules and a security group
  holds 60, so each port has its own group (`mss-frontend-cloudfront-https`,
  `-http`). The monitoring server's probes still reach 443 over the private
  network.
- **A secret header.** CloudFront adds `X-Origin-Verify: <random>` and nginx
  answers 403 without it (except from inside the VPC). Otherwise anyone could
  point their own CloudFront distribution at our server and skip the WAF.
- **Real client IPs.** nginx takes the viewer's address from
  `X-Forwarded-For`, but only on connections from CloudFront's addresses, so
  logs, Loki and the WHIP proxy see the viewer, not CloudFront.
- **Two certificates.** CloudFront uses a free ACM certificate (renewed by
  AWS). The frontend keeps its Let's Encrypt certificate for the CloudFront →
  frontend leg; a *staging* certificate there makes CloudFront answer 502.
- **Let's Encrypt HTTP-01** goes through CloudFront on plain HTTP
  (`/.well-known/acme-challenge/*` → frontend port 80, not cached).
- **Caching.** `/hls/*` and `/dash/*` are cached for 1 second (DASH's
  `no-cache` is obeyed); everything else, including WHIP/WHEP, isn't cached.

## Going from `count` to `block`

1. Use the site, the phone camera and WebRTC for a while.
2. Look at what would have been blocked:
   ```bash
   $(terraform output -raw waf_log)
   ```
   Each record shows the rule (`terminatingRuleId`, or
   `nonTerminatingMatchingRules` in count mode), the client IP and the URI.
   The `Authorization` header (the phone's password) is redacted.
3. If a legitimate request shows up, override that one rule to `count` in
   `waf.tf` (like `SizeRestrictions_BODY`), then set `waf = "block"`.

## Cost

About $5/month for the web ACL, $1/month per rule (5), $0.60 per million
requests, plus CloudFront data transfer (the first 1 TB/month is free).
