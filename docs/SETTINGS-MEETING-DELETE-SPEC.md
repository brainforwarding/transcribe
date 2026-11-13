# New meeting, grouped Settings and deleting

Status: second draft, 2026-11-12. Implemented in the working tree, all suites pass, installed locally as 2.2.0 (19), Figma page 01 updated and both proposal pages removed (2026-11-13). An independent reviewer checked the first draft against the code; its findings are applied and listed at the end. The owner approved the Figma proposals "New meeting and Settings" and "Delete dictations and meetings", and renaming "Save to" to "Meeting exports".

## Outcome

1. New meeting holds only what changes per meeting: title, Online meeting or In person, language, Start meeting.
2. Everything configured once lives in Settings, in five groups that read like macOS System Settings.
3. A dictation or a meeting can be deleted. Deleted items go to the macOS Trash and can be brought back.

House rule: no taglines, helper text or status tags.

## Design

Figma file "Transcribe" (`501FiwrHn8ZJlwbgzjTDly`):

Page "01 · Transcribe 2.2.0", boards "2.2.0 · New meeting", "2.2.0 · Deleting", "2.2.0 · Settings" and "2.2.0 · Settings · credential states". They replaced the two 💡 proposal pages this spec was written from.

## 1. New meeting

`MeetingSetupView` (`MeetingWorkspaceView.swift`) becomes, top to bottom:

1. "New meeting" title.
2. The meeting title field, unchanged.
3. One row, left-aligned with 12 pt between items: the Online meeting / In person segmented picker, then the meeting language picker when `meetingLanguageOptions` is not empty. Nothing is pushed to the right edge.
4. At most one line naming the first thing that keeps Start meeting disabled, with one button. Nothing when nothing blocks:
   - "Microphone isn’t allowed" · **Allow** (a denied microphone opens System Settings);
   - "Add your OpenAI API key" (or Team token) · **Settings**;
   - "OpenAI API key not accepted" · **Settings**;
   - "Agree to tell participants before recording" · **Settings**;
   - Online meeting only: "Mac audio isn’t allowed" · **Allow**. After Allow, macOS applies the permission only after a relaunch, so the line becomes "Reopen Transcribe to use Mac audio" · **Reopen** (`Permissions.relaunch()`, disabled while busy).
5. **Start meeting** and **Cancel**, unchanged, including today's disabled rule.

Permissions are refreshed when the app becomes active again, so returning from System Settings updates the line.

Removed:

- The Microphone card. The picker is already in Settings and stays there.
- The Mac audio card with its description and the Allowed tag.
- "Let everyone know before you record." Consent is accepted once (`consentAccepted`, in setup and in Settings).

## 2. Settings

`SettingsView` is one scrolling page with the "Settings" title and five groups. Each group has:

- a section label (13 pt semibold, muted) above it;
- a container with `DesignSystem.page` fill, a 1 pt `DesignSystem.border` outline and a 12 pt corner radius;
- rows at least 48 pt high with 16 pt side padding: label (15 pt medium) on the left and controls right-aligned;
- a hairline divider between rows, inset 16 pt from the leading edge.

Every in-row control is a native macOS control of regular size: pickers in `.menu` style and buttons in the system bordered style. That way menus and buttons share one height and right edge. `CirclesButtonStyle` is not used inside groups.

The sections and their rows:

| Group | Row | Controls |
|---|---|---|
| Dictation | Start / finish | key cap "⌥ ⌥ / ⌥" |
| | Additional shortcut | picker (existing choices) |
| | Paste last | key cap "⌥ ⇧ V", switch |
| | Check dictation | **Check…** opens `DictationCheckView` in a sheet, with a **Done** button |
| Transcription | Languages | the existing multi-select menu |
| | Microphone | `MicrophonePicker` |
| | Keep audio | 7 days / 30 days / Forever |
| | Meeting exports | folder path (13 pt muted, truncated at the head), **Change** |
| Connection | Service | OpenAI / Team picker (`ConnectionProviderPicker`) |
| | OpenAI API key or Team token | `KeyStatusLabel`, then Unlock (when needed) and Add / Replace / Cancel |
| Permissions | Microphone, Mac audio, Cursor insertion, Shortcuts | a check mark (SF Symbol `checkmark`, success color, accessibility label "Allowed") or **Allow** |
| App | Show in Dock | switch |
| | Appearance | System / Light / Dark |

Other rules:

- When Replace or Add is pressed, `KeyField` appears inside the Connection group, under its row. It uses native controls: a rounded secure field and **Connect**. It has no Unlock and no status line (the row shows both), and no "Stored securely in your Mac’s Keychain." line. Setup keeps its current `KeyField`.
- Mac audio shows **Reopen** instead of Allow after Allow was pressed, as in New meeting.
- Permissions refresh on appear and whenever the app becomes active. Today the check block's 2 s timer did this; in a sheet it no longer runs while Settings is shown.
- The Check dictation sheet ends its instructions with "Come back here when the text appears." instead of pointing to Settings.
- The consent block (shown only while `consentAccepted` is false) stays directly below the Permissions group, with a native **Continue** and without the "Audio is sent to OpenAI…" line.

Removed from Settings:

- "Double to start · Single to finish".
- The "⌘ Tab" key cap.
- "Enable shortcut" next to the Paste last switch; the switch has accessibility label "Paste last shortcut".
- The inline Check dictation block. It moves to the sheet. Setup keeps its inline copy.
- **Import recordings…** It becomes **File › Import Recordings…** (no shortcut), after Open…, calling `importLegacyRecordings()`.
- **Quit Transcribe.** ⌘Q and the menu bar menu remain.
- Both dividers.

"Save to" is renamed **Meeting exports** everywhere it is shown, and in `README.md` and `TranscribeBar/README.md`.

## 3. Deleting

### Store

`SessionStore.moveToTrash(_ id: UUID, using trash: (URL) throws -> URL) throws -> URL` moves the record's folder (record.json, audio, chunks, Ogg copy) to the Trash and returns where it went.

`SessionStore.restore(from trashed: URL, id: UUID) throws -> SessionRecord` moves the folder back to `directory(for: id)` and decodes it. It fails without changing anything if the target exists.

The trash function is injected so that tests never touch the real Trash. Its default throws; only `Operations.live()` passes `FileManager.default.trashItem`. The app is not sandboxed, so this works. Records load at launch, so a folder put back from the Trash in Finder appears after the next launch; Undo is immediate.

A meeting's Markdown export in the Meeting exports folder is never deleted.

### App model

`AppModel.Operations` gains `trash: (URL) throws -> URL`. `AppModel` adds the following.

Invariant: every write to a record folder goes through `mutate()`, which needs the record in `records`, or happens during an active phase that `canDelete` refuses. So nothing can recreate a deleted folder. Later code must keep this.

- `canDelete(_ id: UUID) -> Bool` is false when:
  - the record is the active session in starting, recording, stopping or transcribing;
  - it is waiting in `importQueue`;
  - its status is `.processing`;
  - an update is in progress.
- `delete(_ id: UUID)`:
  1. Return if `!canDelete`.
  2. Move the folder to the Trash. If that fails, nothing changes and `statusDetail` says "Couldn’t move to the Trash."
  3. Cancel the record's summary task (its own cleanup removes it) and drop its pending title, notes and summary edits, so `commitPendingEdits()` and the update lock keep working.
  4. Remove the record from `records`. Clear `activeSessionID`, `chipRecordID` (and hide the chip), `automaticDeliveryID` and `lastTranscript` where they point at it, so Copy, Retry or Open never act on another record.
  5. For a meeting with an export, remember the export path (preference `deletedExports`). **File › Import Recordings…** skips those files, so a deleted meeting does not come back. Undo removes the path again.
  6. Clear `selectedRecordID` if it pointed at it. For a meeting, select the next meeting in the visible list instead, or the previous one if it was last.
  7. For a dictation, keep `(id, trashedURL, kind)` as `lastDeleted` and show the notice.
- `undoDelete()`:
  1. Restore `lastDeleted` with `SessionStore.restore`.
  2. Insert the record back in `records` in start-time order.
  3. Clear `lastDeleted`.
  4. If restore fails (the Trash was emptied, or the item moved), `statusDetail` says "Couldn’t restore from the Trash."

### Dictation

- **Context menu.** Right-click (or Control-click) on an entry shows **Copy** (when it has text) and **Delete**.
- **Hover.** While the pointer is over an entry that `canDelete`, a **Delete** text button in the error color appears before Copy. Its space is always reserved, so the text never reflows. VoiceOver gets a "Delete" action on the entry.
- **No confirmation.** The entry disappears at once.
- **Undo notice.** The bottom-right notice shows "Dictation deleted" with **Undo** for 8 seconds:
  - It uses the existing notice frame. Undo shows only while `lastDeleted` is set and the notice text is "Dictation deleted".
  - Any other notice, a dismiss or a newer delete drops the Undo; the 8 s timer clears only its own notice.
  - After it closes the item stays in the Trash, where Finder can put it back.

### Meeting

- **Where.** **Delete meeting…** (destructive role) is the last item in the meeting page's ⋯ menu, after a divider. It is also in a context menu on the meeting's row in the list. It is disabled when `!canDelete`.
- **Confirmation.** A confirmation alert asks first:
  - title `Delete “<title>”?`;
  - message "The transcript and the recording move to the Trash. The exported file in your Meeting exports folder is kept.";
  - buttons **Cancel** (default, Return and Escape) and **Delete** (destructive).
- **No Undo notice**, because it was confirmed.

### Differences from the Figma proposal

- **No Delete key** for dictations. Dictation entries have no selection to act on.
- **Undo restores from the Trash** instead of delaying the move. A quit during the 8 seconds can't lose or half-delete anything.

- ⌥⇧V and "Copy last" use the newest dictation with text, so after a delete they use the one before. Undo makes the restored one newest again. A paste already in flight stops at its own id check.

## Order of work

1. Store: `moveToTrash` and `restore`, with selftests.
2. Model: `Operations.trash`, `canDelete`, `delete`, `undoDelete`, plus a notice with an action. Coordinator tests.
3. Dictation and meeting delete UI.
4. New meeting.
5. Settings groups, the Check dictation sheet, File › Import Recordings…, Meeting exports.
6. READMEs.
7. Figma: page 01 shows the final screens; both proposal pages are deleted.

## Verification

- **Core selftest:**
  - move to the Trash, then restore, gives back an identical record;
  - restore refuses an existing target;
  - a failing trash function leaves the folder in place.
- **Coordinator:**
  - a deleted dictation leaves `records` and its folder, and Undo restores it;
  - no chip or pending edit points at a deleted record, and `commitPendingEdits()` still succeeds;
  - another notice drops Undo; Undo after the Trash was emptied shows the error;
  - the active recording, a queued import and a processing record cannot be deleted;
  - deleting the selected meeting selects the next one, then the previous one when it was last;
  - a trash failure keeps the record and sets the notice;
  - deleting a meeting with a summary task running cancels it, and no title or summary is written afterwards;
  - New meeting starts with the selected language (existing test).
- **Existing suites:** native, updater and live-follow pass unchanged.
- **Release build installed on the owner's Mac:**
  - delete and Undo a dictation;
  - delete a meeting, find it in the Trash and check that Finder's Put Back works;
  - Mac audio Allow, then Reopen;
  - check the New meeting and Settings layouts against Figma in light and dark.

## Out of scope

- Deleting several items at once.
- Emptying or managing the Trash.
- Deleting Markdown exports.
- A Delete key.

## Review of the first draft

An independent reviewer read the first draft against the code. Applied:

- Pending notes and summary edits are dropped too. Otherwise `commitPendingEdits()` and the update lock would fail forever.
- Every id that can point at a record is cleared, so the chip's Copy or Retry cannot act on another record.
- The trash function's default throws; fixtures can no longer reach the real Trash.
- Import skips the exports of deleted meetings.
- The Undo action is tied to its notice; any other notice drops it.
- Permissions refresh when the app becomes active; Mac audio offers Reopen after Allow.
- New meeting names what blocks Start, now that its cards are gone.
- `KeyField` and the consent block use native controls in Settings, and their helper lines are dropped.
- The check sheet's copy, the reserved space for Delete, and VoiceOver's Delete action.

Not applied:

- Edit › Undo (⌘Z) for a deleted dictation. Replacing the system Undo would break undo in text fields.
- Pausing the 8 s timer on hover.
- Using `NSWorkspace.recycle` instead of `trashItem`. Put Back is a release check instead.
