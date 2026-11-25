## The stance schema: what a policy (LLM or scripted) may say, and how a reply
## is parsed strictly against the canonical JSON contract.
##
## RUNE DISCIPLINE. Every cap here is measured in RUNES (Unicode codepoints)
## and every truncation lands on a rune boundary (`runeLen` / `runeSubStr`).
## Slicing a string by BYTE index anywhere on the path to the replay is
## forbidden: a byte-truncated multi-byte character renders fine in a browser
## and then fails a strict UTF-8 parser, which is exactly the class of bug
## that makes a replay unreadable to everything except the one lenient viewer.

import std/[json, strutils, unicode]
import sim_types

type
  Mode* = enum
    ## What the seat is going for. A closed enum: an unrecognised mode keeps
    ## LAST turn's value (else `clear`), never nothing.
    mdClear = "clear"
    mdHunt = "hunt"
    mdStrike = "strike"
    mdSafe = "safe"
    mdBank = "bank"

  Zone* = enum
    znNone = "none"
    znNw = "nw"
    znNe = "ne"
    znSw = "sw"
    znSe = "se"
    znCentre = "centre"
    znLeft = "left"
    znRight = "right"
    znTop = "top"
    znBottom = "bottom"

  FireMode* = enum
    fmAuto = "auto"
    fmHold = "hold"
    fmNever = "never"

  StanceSource* = enum
    stLlm = "llm"
    stScripted = "scripted"
    stFallback = "fallback"

  LaneStance* = object
    ## One seat's whole decision for one 120-tick turn.
    note*: string              ## <= MaxNoteRunes.
    mode*: Mode
    zone*: Zone
    riskMilli*: int32          ## risk quantised to 0..1000.
    leadTicks*: int32          ## 0..48.
    fire*: FireMode
    say*: string               ## <= MaxSayRunes, sanitized.
    source*: StanceSource
    latencyMs*: int

  StanceError* = object of ValueError

const
  DefaultStance* = LaneStance(
    note: "",
    mode: mdClear,
    zone: znNone,
    riskMilli: 500,
    leadTicks: 14,
    fire: fmAuto,
    say: "",
    source: stScripted
  )

proc truncateRunes*(text: string, limit: int): string =
  ## Cuts `text` to at most `limit` RUNES, on a rune boundary. The single
  ## place any recorded string is shortened.
  if limit <= 0:
    return ""
  if text.runeLen <= limit:
    return text
  text.runeSubStr(0, limit)

proc sanitizeSay*(text: string): string =
  ## A seat's spectator line: capped at MaxSayRunes on a rune boundary FIRST,
  ## then run through the starter's printable-ASCII shout filter. In that
  ## order, so the rune cut never leaves half a codepoint for the filter to
  ## smear. Braces are excluded deliberately — the replay chat stream tells a
  ## CONTROL record from a spoken line by a leading '{'.
  result = ""
  for rune in text.truncateRunes(MaxSayRunes).runes:
    let value = int(rune)
    if value >= 32 and value < 127 and value != ord('{') and
        value != ord('}'):
      result.add($rune)
  result = result.strip()

proc sanitizeNote*(text: string): string =
  ## The policy's own line, as it reaches the replay and the match feed.
  ## Newlines collapse to spaces so one record stays one line.
  text.replace("\n", " ").replace("\r", " ").strip().truncateRunes(MaxNoteRunes)

proc parseMode*(text: string): Mode =
  ## Exact canonical mode string; rejects synonyms and unknown values.
  for mode in Mode:
    if $mode == text:
      return mode
  raise newException(StanceError, "invalid mode: " & text)

proc parseZone*(text: string): Zone =
  ## Exact canonical zone string; rejects synonyms and unknown values.
  for zone in Zone:
    if $zone == text:
      return zone
  raise newException(StanceError, "invalid zone: " & text)

proc parseFire*(text: string): FireMode =
  ## Exact canonical fire mode string; rejects synonyms and unknown values.
  for mode in FireMode:
    if $mode == text:
      return mode
  raise newException(StanceError, "invalid fire mode: " & text)

proc stripOuterJsonFence(text: string): string =
  ## Accepts a raw JSON object or a single standard outer Markdown JSON fence
  ## (```json ... ``` or ``` ... ```), with no surrounding prose.
  let trimmed = text.strip()
  if not trimmed.startsWith("```"):
    return trimmed
  let firstNl = trimmed.find('\n')
  if firstNl < 0 or not trimmed.endsWith("```"):
    raise newException(StanceError, "unterminated Markdown JSON fence")
  let lang = trimmed[3 ..< firstNl].strip().toLowerAscii()
  if lang.len > 0 and lang != "json":
    raise newException(StanceError, "unsupported fence language: " & lang)
  let bodyEnd = trimmed.len - 3
  if bodyEnd <= firstNl + 1:
    raise newException(StanceError, "empty Markdown JSON fence")
  trimmed[firstNl + 1 ..< bodyEnd].strip()

proc extractJsonObject*(text: string): JsonNode =
  ## Parses a single JSON object, optionally wrapped in a standard outer
  ## Markdown JSON fence. Rejects surrounding prose and non-object JSON.
  let body = stripOuterJsonFence(text)
  if body.len == 0:
    raise newException(StanceError, "empty reply")
  try:
    result = parseJson(body)
  except JsonParsingError as error:
    raise newException(StanceError, "invalid JSON object in reply: " & error.msg)
  if result.kind != JObject:
    raise newException(StanceError, "reply must be a JSON object")

proc parseLaneStance*(payload: JsonNode): LaneStance =
  ## Validates one canonical stance JSON object.
  ## Required field: `mode`.
  ## Optional fields take fixed documented game defaults when omitted (never
  ## inherited from a previous turn, never guessed or corrected when invalid):
  ## `zone`="none", `risk`=0.5, `lead_ticks`=14, `fire`="auto", `note`="", `say`="".
  if payload.isNil or payload.kind != JObject:
    raise newException(StanceError, "stance payload must be a JSON object")

  if not payload.hasKey("mode") or payload["mode"].kind != JString:
    raise newException(StanceError, "missing or non-string mode")
  let mode = parseMode(payload["mode"].getStr())

  var zone = znNone
  if payload.hasKey("zone"):
    if payload["zone"].kind != JString:
      raise newException(StanceError, "zone must be a string")
    zone = parseZone(payload["zone"].getStr())

  var riskMilli = 500'i32
  if payload.hasKey("risk"):
    let riskNode = payload["risk"]
    let riskVal =
      case riskNode.kind
      of JInt: float(riskNode.getBiggestInt())
      of JFloat: riskNode.getFloat()
      else:
        raise newException(StanceError, "risk must be a number in 0..1")
    if riskVal != riskVal or riskVal < 0.0 or riskVal > 1.0:
      raise newException(StanceError, "risk out of range 0..1")
    riskMilli = int32(clamp(int(riskVal * 1000.0 + 0.5), 0, 1000))

  var leadTicks = 14'i32
  if payload.hasKey("lead_ticks"):
    if payload["lead_ticks"].kind != JInt:
      raise newException(StanceError, "lead_ticks must be an integer in 0..48")
    let leadVal = payload["lead_ticks"].getBiggestInt()
    if leadVal < 0 or leadVal > 48:
      raise newException(StanceError, "lead_ticks out of range 0..48")
    leadTicks = int32(leadVal)

  var fire = fmAuto
  if payload.hasKey("fire"):
    if payload["fire"].kind != JString:
      raise newException(StanceError, "fire must be a string")
    fire = parseFire(payload["fire"].getStr())

  var note = ""
  if payload.hasKey("note"):
    if payload["note"].kind != JString:
      raise newException(StanceError, "note must be a string")
    note = sanitizeNote(payload["note"].getStr())

  var say = ""
  if payload.hasKey("say"):
    if payload["say"].kind != JString:
      raise newException(StanceError, "say must be a string")
    say = sanitizeSay(payload["say"].getStr())

  LaneStance(
    note: note,
    mode: mode,
    zone: zone,
    riskMilli: riskMilli,
    leadTicks: leadTicks,
    fire: fire,
    say: say,
    source: stLlm,
    latencyMs: 0
  )

proc actionJson*(stance: LaneStance): JsonNode =
  %*{"note": stance.note, "mode": $stance.mode, "zone": $stance.zone,
    "risk": float(stance.riskMilli) / 1000.0, "lead_ticks": stance.leadTicks,
    "fire": $stance.fire, "say": stance.say}

proc risk*(stance: LaneStance): float {.inline.} =
  ## The quantised risk as a fraction. Lives OUTSIDE the determinism boundary
  ## (the autopilot may use floats; the sim may not).
  float(stance.riskMilli) / 1000.0

proc stanceRecord*(
  stance: LaneStance, turn, seat, lane: int, alias: string
): JsonNode =
  ## The replay chat record for one turn's stance. Re-applied at playback
  ## into NON-HASHED fields only, so it can never affect the simulation.
  %*{
    "k": "stance",
    "turn": turn,
    "seat": seat,
    "alias": alias,
    "lane": lane,
    "source": $stance.source,
    "latency_ms": stance.latencyMs,
    "note": stance.note,
    "mode": $stance.mode,
    "zone": $stance.zone,
    "risk": float(stance.riskMilli) / 1000.0,
    "lead_ticks": stance.leadTicks,
    "fire": $stance.fire,
    "say": stance.say
  }

proc boundedStanceRecord*(
  stance: LaneStance, turn, seat, lane: int, alias: string
): string =
  ## The serialized stance record, guaranteed <= MaxStanceRunes. The note is
  ## the only unbounded-in-practice field, so it is the one that shrinks; the
  ## cut still lands on a rune boundary. NEVER cut the serialized string —
  ## that would emit broken JSON, the exact failure the rune rule prevents.
  var trimmed = stance
  result = $stanceRecord(trimmed, turn, seat, lane, alias)
  var guard = 0
  while result.runeLen > MaxStanceRunes and guard < 12:
    inc guard
    let keep = max(0, trimmed.note.runeLen - max(8, trimmed.note.runeLen div 2))
    trimmed.note = trimmed.note.truncateRunes(keep)
    trimmed.say = trimmed.say.truncateRunes(max(0, trimmed.say.runeLen - 2))
    result = $stanceRecord(trimmed, turn, seat, lane, alias)

proc registerRecord*(
  seat, lane: int, alias, policy, kind, baseline: string
): string =
  ## The REDACTED registration record. The seat's prompt is NEVER written:
  ## only the policy label, the kind and which baseline a scripted seat
  ## picked.
  $(%*{
    "k": "register",
    "seat": seat,
    "alias": alias,
    "lane": lane,
    "policy": policy.truncateRunes(MaxPolicyLabelRunes),
    "kind": kind,
    "baseline": baseline
  })

proc fallbackRecord*(
  turn, seat, attempt: int, cause, detail: string
): string =
  $(%*{
    "k": "fallback",
    "turn": turn,
    "seat": seat,
    "attempt": attempt,
    "cause": cause,
    "detail": detail.truncateRunes(MaxFallbackDetailRunes)
  })

proc missedTurnRecord*(turn, seat: int, cause: string): string =
  $(%*{
    "k": "missed_turn",
    "turn": turn,
    "seat": seat,
    "cause": cause
  })

proc budgetGuardRecord*(turn, remainingSeconds: int): string =
  $(%*{"k": "budget_guard", "turn": turn, "remaining_s": remainingSeconds})

proc stoppedRecord*(tick: int): string =
  $(%*{"k": "stopped", "tick": tick, "reason": EndRuleWallClock})
