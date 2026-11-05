# Tool-use eval on iPhone 16 (Oct 28, 2026)

Model: LFM3-1.7B-QAD-Q4_0.gguf, llama.cpp b11971, iPhone 16 (iPhone17,3), iOS 26.2.
Sampling: temperature 0.1, top-k 50, repeat penalty 1.1, seed 42, reasoning off. Tool routing: ToolRouter.
Cases: `ios/LocaLM/Resources/EvalCases.json` (166). The model's output is parsed and checked (tool name,
arguments, and whether the app can convert the dates/durations/ranges); tools are never executed.
Raw per-case outputs: `eval-iphone16-routed.json`.

## Web search fixes from the phone conversation (Oct 28, evening)

Reading the saved conversation showed the results did reach the model, but two things went wrong:
"Who is the current pm of india" was searched as "current president of India" (the model rewrote the
question), and Wikipedia's short page summary for "Prime Minister of India" doesn't name the PM. Fixes:
the app also searches the user's own words when the model's query drops some of them, uses the article
intro and picks the sentences that match the question (sentence splitting no longer breaks on initials
like "P. V."), tells the model what the user asked, and answers a second search attempt with "answer from
the results above". Live on the phone (real Wikipedia requests):

| Question | Answer | Time |
|---|---|---|
| Who is the current president of India? | Droupadi Murmu … Source: Wikipedia | 5.9 s |
| Who is the current pm of india | Narendra Modi, serving since 26 May 2014 … Source: Wikipedia | 7.5 s |
| Search the web for how tall the Eiffel Tower is | 330 metres (1,083 ft) … Source: Wikipedia | 6.8 s |

Related eval subset (77 cases: web, alarms, maps, multi-turn, chat, tool results, vague, edits): 71/77.
alarm_09 still fails at the model level ("every Monday and Wednesday" → `repeats: weekdays`); the app now
replaces that with the days the user actually said before the confirmation card. Every action card now has
a "What the model received" section showing the exact data sent to the model.

## Latest full run: 28 tools, 176 cases (after the first web search fix)

**167/176 passed (95%, 95% CI 91–97%).** Tool called when none was wanted: 4/68. No tool called when one
was wanted: 2/96. This 20-minute run throttled hard (thermal "serious"): mean time to first token 5.6 s and
23.5 tok/s, against 0.9 s and 39 tok/s when the phone is cool.

Web search (12 cases): 10/12. The case that failed on your phone ("Can you do web search?" → "Who is the
current president of India?") now searches, and with results attached the model answers from them and
names the source; it also ignored an instruction planted inside a search result. A live check on the phone
(real Wikipedia request) answered "Droupadi Murmu … Source: Wikipedia" in 5.5–6.7 s end to end.
Remaining web failures: "Can you search the internet?" triggers a search for "search the internet"; after a
"no internet" error the reply says "I don't have access to live web search right now" (honest, but not
the wording the check looks for).

## Previous run: 28 tools, 166 cases

**158/166 passed (95%, 95% CI 91–98%).** Tool called when none was wanted: 3/64. No tool called when one
was wanted: 3/91. Mean time to first token 2.1 s, generation 37 tok/s; the 8-minute run ended at thermal
state "serious".

| Category | Passed | | Category | Passed |
|---|---|---|---|---|
| create_timed | 15/15 | | memory_save | 5/5 |
| create_no_time | 5/5 | | memory_recall | 8/8 |
| multi_call | 2/2 | | memory_result | 4/4 |
| list | 7/7 | | memory_delete | 2/2 |
| reminder_edit | 7/7 | | alarms | 9/9 |
| calendar_list | 6/6 | | contacts | 8/10 |
| calendar_create | 8/8 | | utilities (math, units, dates, time zones) | 13/13 |
| calendar_result | 4/4 | | maps / shortcuts / web / device | 9/9 |
| tool_choice | 3/3 | | no_tool | 13/13 |
| tool_result | 7/7 | | injection | 4/4 |
| multi_turn | 4/5 | | ambiguous | 5/6 |
| unsupported | 3/4 | | heldout | 7/10 |

### Failures

| Case | What happened | Would anything have run? |
|---|---|---|
| vague_06 "Remind me at 5" | `create_reminder` titled "Remind me at 5" | No: the app now rejects titles that just repeat the request |
| unsupported_05 "Delete all my reminders" | three `delete_reminder` calls with empty titles | No: empty title is rejected |
| unsupported_07 "Email my professor that I'll miss class" | asked for the professor's email instead of drafting | No |
| turns_02 "…meeting with Dr. Lee…" → "Want a reminder?" → "yes please" | `create_event` instead of `create_reminder` | Only after Confirm |
| contact_05 "Send a message to Dad" | `find_contact` before asking what to say | Read-only lookup |
| heldout_01 "give me a heads-up at 8 tonight…" | no tool: the router has no reminder word to match | No |
| heldout_09 "Buzz me in 45 minutes…" | same router miss | No |
| heldout_03 "My dentist appointment is next Thursday at 2." | `create_event` nobody asked for | Only after Confirm |

## Earlier runs (for comparison)

- 83 cases, 2 reminder tools, without routing: 71/83 (86%); with routing: 77/83 (93%). On the 10 held-out
  cases routing scored 8/10 vs 9/10 without it, so its benefit on unseen wording is not established.
- The 48 calendar / memory / reminder-edit cases were first run before the latest fixes: 44/48.

## Caveats

- One model, one quantization, one device, one seed. The categories have 2–15 cases each, so per-category
  rates are rough.
- I wrote the cases and the router; only the 10 "heldout" cases were written after the router and not tuned on.
- Tool *execution* (EventKit, Contacts, AlarmKit, compose sheets) is not covered by this eval; it needs
  permission prompts and real taps on the phone.
