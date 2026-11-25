## Strict canonical stance parsing: raw JSON or standard outer Markdown JSON
## fence, only `mode` required, fixed documented defaults for omitted optionals,
## no synonyms or silent repairs, and every free-text truncation lands on a RUNE
## boundary.

import std/[json, strformat, strutils, unicode]
import lane_helpers
import lane/[sim_types, stances]

proc parsed(text: string): LaneStance =
  parseLaneStance(extractJsonObject(text))

proc assertRejected(text: string, label: string) =
  var raised = false
  try:
    discard parsed(text)
  except StanceError, JsonParsingError:
    raised = true
  check(raised, &"expected rejection for {label}, but reply was accepted")

proc testMinimalAndMarkdownFence() =
  let minimal = parsed("""{"mode":"hunt"}""")
  check(minimal.mode == mdHunt and minimal.zone == znNone and
        minimal.riskMilli == 500 and minimal.leadTicks == 14 and
        minimal.fire == fmAuto and minimal.note == "" and minimal.say == "",
        "minimal mode-only stance did not receive fixed defaults")
  let fencedMinimal = parsed("```json\n{\"mode\":\"strike\"}\n```")
  check(fencedMinimal.mode == mdStrike and fencedMinimal.zone == znNone and
        fencedMinimal.riskMilli == 500 and fencedMinimal.leadTicks == 14 and
        fencedMinimal.fire == fmAuto,
        "fenced minimal stance did not parse with fixed defaults")
  let bareFence = parsed("```\n{\"mode\":\"bank\",\"zone\":\"sw\",\"risk\":0.2,\"lead_ticks\":8}\n```")
  check(bareFence.mode == mdBank and bareFence.zone == znSw and
        bareFence.riskMilli == 200 and bareFence.leadTicks == 8,
        "standard outer ``` fence did not parse")
  let full = parsed("""{"note":"power pellet in sw","mode":"hunt","zone":"sw","risk":0.55,"lead_ticks":16,"fire":"hold","say":"going sw"}""")
  check(full.mode == mdHunt and full.zone == znSw and full.riskMilli == 550 and
        full.leadTicks == 16 and full.fire == fmHold and full.say == "going sw",
        "full canonical JSON did not parse")
  report("minimal mode-only JSON, full JSON, and outer Markdown JSON fence parse")

proc testProseAndMalformedRejected() =
  assertRejected(
    "Sure! Here is my plan.\n```json\n{\"mode\":\"hunt\"}\n```",
    "prose-prefixed fenced JSON")
  assertRejected(
    "{\"mode\":\"hunt\"}\nHope that helps!",
    "prose-suffixed JSON")
  assertRejected("I would rather not say.", "plain prose")
  assertRejected("[]", "JSON array")
  assertRejected("""{"weather":"fine"}""", "object without mode")
  assertRejected("""{"note":"only a note"}""", "note-only object")
  assertRejected("""{"zone":"sw","risk":0.5,"lead_ticks":12}""", "missing required mode")
  report("prose-wrapped, malformed, and mode-less replies are rejected")

proc testRiskValidation() =
  check(parsed("""{"mode":"clear","risk":0}""").riskMilli == 0, "risk 0 failed")
  check(parsed("""{"mode":"clear","risk":1}""").riskMilli == 1000, "risk 1 failed")
  check(parsed("""{"mode":"clear","risk":0.25}""").riskMilli == 250, "risk 0.25 failed")
  for bad in ["55", "\"0.25\"", "\"85%\"", "9.9", "140", "-0.1", "null", "true"]:
    assertRejected(&"""{{"mode":"clear","risk":{bad}}}""", &"risk={bad}")
  report("risk accepts only JSON numbers in [0, 1]; percentages/strings/out-of-range rejected")

proc testModeAliasesRejected() =
  for canonical in ["clear", "hunt", "strike", "safe", "bank"]:
    let stance = parsed(&"""{{"mode":"{canonical}"}}""")
    check($stance.mode == canonical, &"canonical mode {canonical} failed")
  for bad in ["greedy", "collect", "attack", "chase", "defend", "dodge",
              "survive", "turtle", "STRIKE", "Bank", "  clear  ", "teleport"]:
    assertRejected(&"""{{"mode":"{bad}"}}""", &"mode={bad}")
  report("canonical modes accepted; synonyms, case variants and unknown modes rejected")

proc testZoneAliasesRejected() =
  for canonical in ["none", "nw", "ne", "sw", "se", "centre", "left", "right", "top", "bottom"]:
    let stance = parsed(&"""{{"mode":"clear","zone":"{canonical}"}}""")
    check($stance.zone == canonical, &"canonical zone {canonical} failed")
  for bad in ["north-west", "top left", "upper left", "north east",
              "bottom right", "lower left", "middle", "center", "anywhere",
              "", "nowhere-at-all", "NW"]:
    assertRejected(&"""{{"mode":"clear","zone":"{bad}"}}""", &"zone={bad}")
  assertRejected("""{"mode":"clear","zone":null}""", "zone=null")
  report("canonical zones accepted; synonyms and unknown zones rejected")

proc testFireAliasesRejected() =
  for canonical in ["auto", "hold", "never"]:
    let stance = parsed(&"""{{"mode":"clear","fire":"{canonical}"}}""")
    check($stance.fire == canonical, &"canonical fire {canonical} failed")
  for bad in ["always", "off", "on", "AUTO", "nonsense"]:
    assertRejected(&"""{{"mode":"clear","fire":"{bad}"}}""", &"fire={bad}")
  assertRejected("""{"mode":"clear","fire":null}""", "fire=null")
  report("canonical fire modes accepted; synonyms and unknown fire modes rejected")

proc testLeadTicksValidation() =
  check(parsed("""{"mode":"clear","lead_ticks":0}""").leadTicks == 0, "lead_ticks 0 failed")
  check(parsed("""{"mode":"clear","lead_ticks":48}""").leadTicks == 48, "lead_ticks 48 failed")
  for bad in ["-5", "49", "999", "\"16\"", "16.5", "null"]:
    assertRejected(&"""{{"mode":"clear","lead_ticks":{bad}}}""", &"lead_ticks={bad}")
  # camelCase alias is ignored/not accepted as lead_ticks; verify lead_ticks stays fixed default or wait:
  # reject non-canonical leadTicks? No extra gates, or verify leadTicks is NOT applied.
  check(parsed("""{"mode":"clear","leadTicks":48}""").leadTicks == 14,
        "camelCase leadTicks alias must not override lead_ticks")
  report("lead_ticks accepts only integers in 0..48; invalid supplied values rejected")

proc testNoteAndSayCaps() =
  let long = "x".repeat(300)
  let stance = parsed(&"""{{"mode":"clear","note":"{long}"}}""")
  check(stance.note.runeLen == MaxNoteRunes,
        &"a 300-char note came out {stance.note.runeLen} runes")
  assertRejected("""{"mode":"clear","note":123}""", "non-string note")
  assertRejected("""{"mode":"clear","say":123}""", "non-string say")
  report("a 300-character note is cut to exactly 160 runes; non-string note/say rejected")

proc testEmojiOnTheBoundary() =
  let say = "a".repeat(47) & "\u{1F600}\u{1F600}"
  check(say.runeLen == 49, "the fixture say is not 49 runes")
  let stance = parseLaneStance(%*{"mode": "clear", "say": say})
  check(stance.say.runeLen <= MaxSayRunes,
        &"say is {stance.say.runeLen} runes, over the cap")
  check(stance.say.validateUtf8() == -1, "say is not valid UTF-8")
  let cut = truncateRunes(say, 48)
  check(cut.runeLen == 48, &"truncateRunes gave {cut.runeLen} runes")
  check(cut.validateUtf8() == -1, "truncateRunes split a codepoint")
  check(cut.endsWith("\u{1F600}"), "truncateRunes dropped the boundary rune")
  var emojiStance = stance
  emojiStance.note = "\u{1F600}".repeat(200)
  emojiStance.note = truncateRunes(emojiStance.note, MaxNoteRunes)
  let record = boundedStanceRecord(emojiStance, 3, 1, 1, "BLUE")
  check(record.runeLen <= MaxStanceRunes,
        &"the stance record is {record.runeLen} runes, over {MaxStanceRunes}")
  check(record.validateUtf8() == -1, "the stance record is not valid UTF-8")
  let reparsed = parseJson(record)
  check(reparsed{"k"}.getStr() == "stance", "the record did not round-trip")
  report("a 4-byte emoji on the boundary: rune-cut, valid UTF-8, round-trips")

proc testRecordCaps() =
  let long = "n".repeat(400)
  var stance = DefaultStance
  stance.note = long
  stance.say = "s".repeat(200)
  let record = boundedStanceRecord(stance, 11, 2, 2, "GREEN")
  check(record.runeLen <= MaxStanceRunes,
        &"an over-long stance record is {record.runeLen} runes")
  check(parseJson(record){"k"}.getStr() == "stance",
        "the shrunk record is not valid JSON")
  let reg = registerRecord(0, 0, "RED", "p".repeat(200), "llm", "none")
  check(parseJson(reg){"policy"}.getStr().runeLen == MaxPolicyLabelRunes,
        "the policy label was not capped at 48 runes")
  let fb = fallbackRecord(3, 1, 2, "timeout", "d".repeat(500))
  check(parseJson(fb){"detail"}.getStr().runeLen == MaxFallbackDetailRunes,
        "the fallback detail was not capped at 200 runes")
  report("register.policy <= 48, fallback.detail <= 200, stance <= 600 runes")

when isMainModule:
  echo "test_stances"
  testMinimalAndMarkdownFence()
  testProseAndMalformedRejected()
  testRiskValidation()
  testModeAliasesRejected()
  testZoneAliasesRejected()
  testFireAliasesRejected()
  testLeadTicksValidation()
  testNoteAndSayCaps()
  testEmojiOnTheBoundary()
  testRecordCaps()
  echo "test_stances OK"
