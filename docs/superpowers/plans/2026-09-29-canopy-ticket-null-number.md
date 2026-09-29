# Tickets Without a Number Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Tickets plugin reads every ticket production ticket-manager sends, including those whose `number` is null, and JSON it cannot read fails with an error that names the field and the ticket instead of blaming the address.

**Architecture:** `TicketSummary.number` becomes optional, as ticket-manager's API declares it.
`TicketAPI` tells a body that is not JSON (`bad_response`, check the address) apart from JSON its models cannot read (`unreadable_answer`, naming the field path and the ticket's channel name).

**Tech Stack:** Swift 6.2, Foundation `JSONDecoder` and `JSONSerialization`, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-09-29-canopy-plugins-design.md`, "Error handling".

## Root Cause

After `canopy ticket connect https://courteous-moose-751.convex.site`, every list failed with "did not answer like ticket-manager: its answer was not the JSON Canopy expects. Check that it is the deployment's .convex.site address."
The address was right: `/api/v1/me` and `/api/v1/tickets` answered 200 with the documented JSON.

ticket-manager's `toTicketSummary` sets `number` from `parseChannelName(name).number`, which is `string | null`.
It is null unless the name is `ticket-` or `closed-`, digits, a dash, and a customer.
Production had 1 of 215 open tickets (`ticket-transcripts`), 1 of 448 closed (`closed-0079`), and 37 of 156 archived (such as `ticket-0043`) with a null number.
Canopy's `TicketSummary.number` was a `String`, so one null failed the whole list, and `TicketAPI` reported every decoding failure as `bad_response` with the address hint.

The fixtures Canopy shares with ticket-manager have no ticket without a number, so no test saw it.
`number` is the only nullable field of a summary that Canopy required: `owner` and `staleHours` were optional already, and the rest come from required columns.

## Decisions

- A list that holds a ticket Canopy cannot read still fails as a whole, rather than leaving the ticket out.
  Leaving it out of an `ids` answer would mark its row missing, and leaving it out of a status list would make references to it fail with `ticket_not_found`.
  A precise error is the better failure while the two sides disagree.
- `unreadable_answer` backs off like `bad_response`, since asking again gets the same answer.
- Nothing in Canopy reads `TicketSummary.number`: labels and references take the number from the channel name through `TicketName`, which already handles `closed-0079` and `ticket-transcripts`.

## Tasks

### Task 1: A ticket without a number decodes

**Files:** `Sources/CanopyTickets/Model/TicketSummary.swift`, `Tests/CanopyTicketsTests/TicketModelTests.swift`, and the `[String]` helpers in `TicketListingTests.swift` and `TicketsCommandTests.swift`.

- [x] Test `aChannelNameWithoutACustomerHasNoNumber`: a list holding `closed-0079` with `"number": null` decodes, its number is nil, its label is still `#0079`, and it survives an encode and decode.
- [x] Make `number` a `String?`, documented with when it is null.

### Task 2: JSON Canopy cannot read says where

**Files:** `Sources/CanopyTickets/API/TicketAPI.swift`, `TicketError.swift`, the new `UnreadableAnswer.swift`, `Tickets/TicketsGuide.swift`, `Tests/CanopyTicketsTests/TicketAPITests.swift`, and the spec's error table.

- [x] Test `anAnswerCanopyCannotReadNamesTheFieldAndTheTicket`: a null `customer`, a string `openedAt`, and a missing `discordUrl` in the second ticket of a list each fail with `.unreadable`, naming `tickets[1].<field>` and `ticket ticket-0001-a`; `me` answering `{"user": "x"}` or `[]` names `email` or the answer itself.
- [x] Test the new case's code, message, warning, and backoff alongside the others.
- [x] `TicketAPI` checks a 200's body with `JSONSerialization` first: not JSON stays `.badResponse("its answer was not JSON")`.
  A `DecodingError` becomes `.unreadable(UnreadableAnswer.reason(error, body:))`.
- [x] `UnreadableAnswer.reason` writes the coding path as `tickets[37].number`, says whether the value is null, of another type, or missing, and adds the channel name of the ticket the path runs through (`tickets[i]` in a list, `ticket` or `messages` in a detail).
- [x] The agent guide says `unreadable_answer` needs an update to Canopy or ticket-manager, so an agent tells the author.
- [x] The spec's error table gets the new row.

### Task 3: Check it against production

- [x] On a dev build of `main`, on a throwaway home, `canopy ticket connect https://courteous-moose-751.convex.site` with the author's token, then `ticket list` and `ticket list --closed`: both fail with the reported message.
- [x] On this branch: 215 open and 604 closed or archived tickets list, `ticket show` prints `closed-0079`, and the window's New Ticket Row picker lists open tickets and, with Closed on, `0079`.
- [x] Disconnect so the throwaway home's Keychain item goes, and quit the dev build by pid.
