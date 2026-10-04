# Janus companion protocol

Janus is a macOS app and an Android app that connect a phone and a computer. Both are built on
the [KDE Connect](https://kdeconnect.kde.org/) protocol and use its standard plugins (battery,
clipboard, notifications, SMS, file sharing, media control and so on) unchanged.

On top of that, Janus adds features through **companion messages**: small messages tunnelled
through two existing KDE Connect packet types, so that they pass through a stock KDE Connect
engine that drops unknown packet types:

- **Phone → computer:** a `kdeconnect.notification` packet whose `id` starts with `ge.connect.`.
- **Computer → phone:** a `kdeconnect.ping` packet whose `message` starts with `ge.connect.`.

The `ge.connect.` prefix is part of the wire format and must be used exactly as written. Every
identifier, JSON key and operation name in this document is likewise literal.

**Versioning.** Companion messages whose payload is JSON carry `"v": 1`. Plain-text payloads
(for example `key=value;…` reports and `name:argument` commands) are unversioned and are extended
only by adding keys or commands, which receivers that don't know them ignore. A phone advertises
the companion features it implements in the `caps` list of its
[device profile](#15-device-profile-geconnectdevice); a computer should only use features listed
there.

In this document, "phone" means the Android app and "Mac" means the macOS app. Nothing in the
format is specific to macOS; another desktop implementation can play the Mac's role.

## Contents

1. [Base protocol](#1-base-protocol)
2. [Transport of companion messages](#2-transport-of-companion-messages)
3. [General rules](#3-general-rules)
4. [Ping (`ge.connect.ping`)](#4-ping-geconnectping)
5. [Do Not Disturb (`ge.connect.dnd`)](#5-do-not-disturb-geconnectdnd)
6. [Transfer size (`ge.connect.transfer`)](#6-transfer-size-geconnecttransfer)
7. [Find Phone state (`ge.connect.ring`)](#7-find-phone-state-geconnectring)
8. [Phone status and toggles (`ge.connect.status`)](#8-phone-status-and-toggles-geconnectstatus)
9. [Mac actions and Mac state (`ge.connect.macaction`, `ge.connect.macstate`)](#9-mac-actions-and-mac-state-geconnectmacaction-geconnectmacstate)
10. [Calls (`ge.connect.dial`, `ge.connect.call`, `ge.connect.callstate`, `ge.connect.callresult`)](#10-calls)
11. [Screenshots (`ge.connect.screenshot`)](#11-screenshots-geconnectscreenshot)
12. [Live activities (`ge.connect.live`)](#12-live-activities-geconnectlive)
13. [Screen mirroring (`ge.connect.mirror`)](#13-screen-mirroring-geconnectmirror)
14. [Calendar (`ge.connect.calendar`)](#14-calendar-geconnectcalendar)
15. [Device profile (`ge.connect.device`)](#15-device-profile-geconnectdevice)
16. [Notes sync (`ge.connect.notes`)](#16-notes-sync-geconnectnotes)
17. [Rich notes format](#17-rich-notes-format)
18. [Quick reference](#18-quick-reference)

---

## 1. Base protocol

- KDE Connect **protocol version 8** (TLS; identity exchanged after the TLS handshake).
- Discovery: UDP broadcast and mDNS `_kdeconnect._udp` on port 1716; TCP on 1716 (range
  1714–1764). Peers may also be added by direct address.
- Pairing: both sides show the same verification key; either side may start pairing.
- Device names: must not contain any of `"',;:.!?()[]<>` and are at most 32 characters. Use the
  typographic apostrophe `’` (for example "Alex’s phone").
- Device type: the phone announces `phone`; the computer announces `desktop` or `laptop`.
- Plugin capabilities are exchanged at connect time as usual. A standard feature disabled on the
  phone therefore disappears on the computer automatically.
- The Android package ID is `ge.connect` (needed for the permission grant in
  [Screen mirroring](#13-screen-mirroring-geconnectmirror)).

## 2. Transport of companion messages

### 2.1 Phone → Mac: companion notification

A companion message from the phone is a standard notification packet:

```json
{ "type": "kdeconnect.notification",
  "body": { "id": "ge.connect.<kind>:<suffix>",
            "appName": "Janus",
            "title": "<kind-specific title>",
            "text": "<payload>",
            "ticker": "",
            "isClearable": true,
            "silent": true,
            "time": "<epoch milliseconds, as a string>" } }
```

- `<kind>` selects the message family (`ping`, `dnd`, `status`, …). The receiver dispatches on the
  `id` prefix `ge.connect.<kind>:` (or the exact id, for the families that use no suffix).
- `<suffix>` is usually a fresh UUID per message. Some families use a stable key instead, or no
  suffix at all; each section says which.
- `text` carries the payload: a short string, a `key=value;…` list, or JSON.
- `title` is informational; receivers must not rely on it.
- `silent` is `true` for every family except [ping](#4-ping-geconnectping).

A companion notification is withdrawn with a cancel packet carrying the same id:

```json
{ "type": "kdeconnect.notification",
  "body": { "id": "ge.connect.<kind>:<suffix>", "isCancel": true } }
```

### 2.2 Mac → phone: ping command

A command from the Mac is a standard ping packet whose message starts with `ge.connect.`:

```json
{ "type": "kdeconnect.ping",
  "body": { "message": "ge.connect.<command>[:<argument>]" } }
```

The argument format depends on the command: a single word (`on`), a colon-separated list, a
`key=value;…` list, or JSON.

## 3. General rules

1. **Never displayed.** A `kdeconnect.notification` whose `id` starts with `ge.connect.` is a
   companion message. It is never shown or listed as a phone notification. A `kdeconnect.ping`
   whose `message` starts with `ge.connect.` is a command. It is never shown as a ping.
2. **Unknown kinds are ignored.** Unknown companion kinds, unknown commands, unknown arguments,
   unknown `key=value` keys and unknown JSON fields are ignored silently.
3. **Cancel and repost for changes.** Stock engines ignore in-place updates to a notification.
   When a notification the phone already sent changes (title, text, ticker, group, conversation,
   actions or picture), the phone sends `isCancel` for its id, then the new packet with the same
   id, back to back (any icon payload is offered again). Unchanged re-posts are not sent. This
   applies to ordinary mirrored notifications and to the companion families that keep a stable id
   (`ge.connect.live`, `ge.connect.callstate`, `ge.connect.calendar`, `ge.connect.device`).
4. **10-second auto-cancel.** A companion notification is cancelled with `isCancel` about 10 s
   after it was sent, so that it doesn't linger in the engine. Exemptions:
   - `ge.connect.live`: lives until the activity ends.
   - `ge.connect.calendar` and `ge.connect.device`: stay posted; replaced by cancel and repost.
   - `ge.connect.callstate`: stays posted until the call ends.
5. **Gating.** The Mac sends `ge.connect.*` commands only to phones that have sent a device
   profile or a status report, and hides features whose capability is missing from the phone's
   `caps`.
6. **Human-readable reasons.** Wherever a reply has the form `…:failed:<reason>`, `<reason>` is
   short English text that is safe to show to the user as-is.

## 4. Ping (`ge.connect.ping`)

**Mac → phone:** a standard `kdeconnect.ping` (a plain ping, not a companion command).

**Phone → Mac:** a companion notification. Stock engines show phone pings poorly, so the phone
sends this instead of a `kdeconnect.ping`.

```json
{ "type": "kdeconnect.notification",
  "body": { "id": "ge.connect.ping:<uuid>",
            "appName": "Janus",
            "title": "Ping",
            "text": "<optional message>",
            "ticker": "",
            "isClearable": true,
            "silent": false,
            "time": "<epoch ms as string>" } }
```

- The Mac shows a notification with the phone's name as the title and `text` as the body, or
  "Ping!" when `text` is empty.
- Cancelled after about 10 s.
- Requires the Mac's notifications plugin to be enabled for the phone (the default).

## 5. Do Not Disturb (`ge.connect.dnd`)

**Mac → phone** commands:

```
ge.connect.dnd:on
ge.connect.dnd:off
```

**Phone → Mac** report, on every DND change and right after connecting:

| Field | Value |
|---|---|
| `id` | `ge.connect.dnd:<uuid>` |
| `title` | `Do Not Disturb` |
| `text` | `on` or `off` |
| `silent` | `true` |

Cancelled after about 10 s.

- Mapping on Android: `on` = interruption filter `PRIORITY`, `off` = `ALL`.
- DND state is also carried by the `dnd` key of the [status report](#8-phone-status-and-toggles-geconnectstatus).
- The Mac only shows and toggles the phone's DND; it does not sync its own Focus state.

## 6. Transfer size (`ge.connect.transfer`)

**Phone → Mac**, right before the first file of a share is sent, and again with a new id whenever
more files join a running share:

| Field | Value |
|---|---|
| `id` | `ge.connect.transfer:<uuid>` |
| `title` | `Transfer` |
| `text` | `<totalBytes>\|<numberOfFiles>` (for example `52428800\|3`) |
| `silent` | `true` |

Cancelled after about 10 s. The Mac matches the marker to the incoming `kdeconnect.share.request`
files to show overall progress. The latest marker wins.

## 7. Find Phone state (`ge.connect.ring`)

**Mac → phone:** a standard `kdeconnect.findmyphone.request`. A second request while the phone is
ringing **stops** the ringing.

**Phone → Mac**, when ringing starts and when it stops:

| Field | Value |
|---|---|
| `id` | `ge.connect.ring:<uuid>` |
| `text` | `on` or `off` |
| `silent` | `true` |

Cancelled after about 10 s.

- The phone rings until it is stopped; there is no timeout.
- The Mac trusts the markers. It may apply a local reset (the Mac app uses 60 s) only when no
  marker arrives.

## 8. Phone status and toggles (`ge.connect.status`)

### 8.1 Status report (phone → Mac)

| Field | Value |
|---|---|
| `id` | `ge.connect.status:<uuid>` |
| `title` | `Status` |
| `text` | `key=value` pairs separated by `;` |
| `silent` | `true` |

Cancelled after about 10 s. Example:

```
ringer=normal;dnd=off;flashlight=off;wifi=HomeNetwork;carrier=ExampleTel;net=5G;storage=81604378624/256060514304;os=Android 16 · One UI 8.5
```

| Key | Values | Notes |
|---|---|---|
| `ringer` | `normal` \| `vibrate` \| `silent` | |
| `dnd` | `on` \| `off` | Also updates the DND state from [§5](#5-do-not-disturb-geconnectdnd). |
| `flashlight` | `on` \| `off` | |
| `wifi` | SSID | Only when the phone app has location access (Android requires it to read the SSID). |
| `carrier` | operator name | |
| `net` | `5G` \| `LTE` \| `3G` \| `2G` | Mobile data type. May be present while on Wi-Fi. |
| `storage` | `<freeBytes>/<totalBytes>` | The free value is only updated after a change of about 1 GB. |
| `os` | free text | For example `Android 16 · One UI 8.5`. |

Rules:

- Any key may be omitted when unknown. Unknown keys are ignored.
- Values never contain `;` or `=`.
- Sent on connect and on every change of a reported value (network changes, ringer, DND,
  flashlight; storage is re-checked when the screen turns off).
- An unchanged report is not resent, except in answer to a `ge.connect.status` request.

### 8.2 Commands (Mac → phone)

```
ge.connect.ringer:normal | ge.connect.ringer:vibrate | ge.connect.ringer:silent
ge.connect.flashlight:on | ge.connect.flashlight:off
ge.connect.dnd:on        | ge.connect.dnd:off
ge.connect.status
```

- The phone answers each ringer, flashlight and DND command with a fresh status report.
- `ge.connect.status` (no argument) means "send your status now"; the phone answers with a report
  even if nothing changed. The Mac sends it when it starts after the phone has already connected
  (and so missed the on-connect report), and only to phones that have reported before.

## 9. Mac actions and Mac state (`ge.connect.macaction`, `ge.connect.macstate`)

### 9.1 Actions via run-command

Mac actions use the standard `kdeconnect.runcommand` plugin. The Mac publishes them in its
command list. Keys starting with `ge-` are reserved for built-in actions; all other keys are
user-defined commands and must keep working as in stock KDE Connect.

| Key | Action |
|---|---|
| `ge-lock` | Lock the Mac. |
| `ge-sleep` | Put the Mac to sleep. |
| `ge-mute` | Toggle mute of the current audio output. |
| `ge-screenshot` | Take a screenshot on the Mac. |
| `ge-findmac` | Toggle a "find my Mac" alert. |
| `ge-displaysleep` | Legacy: sleep the display. No longer published, but still honoured if sent. |

A phone may choose not to display some actions (the Android app hides `ge-sleep`, since locking
covers it). The Mac may still publish them.

### 9.2 Action results (Mac → phone)

```
ge.connect.macaction:<id>:ok
ge.connect.macaction:<id>:failed:<reason>
```

`<id>` is the run-command key without the `ge-` prefix (for example `lock`, `mute`). `sleep`
answers before the Mac goes to sleep.

### 9.3 Mac state (Mac → phone)

```
ge.connect.macstate:muted=on|off|na;finding=on|off;locked=on|off;model=<model id>;kind=laptop|desktop;market=<marketing name>
```

Example:

```
ge.connect.macstate:muted=off;finding=off;locked=off;model=Mac15,3;kind=laptop;market=MacBook Pro
```

| Key | Values | Notes |
|---|---|---|
| `muted` | `on` \| `off` \| `na` | `na` = the current output has no volume control. |
| `finding` | `on` \| `off` | State of the `ge-findmac` alert. |
| `locked` | `on` \| `off` | |
| `model` | hardware model identifier | For example `Mac15,3`. |
| `kind` | `laptop` \| `desktop` | The phone uses it to pick a laptop or desktop icon. |
| `market` | marketing name | For example `MacBook Pro`. The phone uses it for the default illustration; matching on the device name is only a fallback. |

- Sent after the phone's first status report on each connection, and on every change.
- The phone remembers `model`, `kind` and `market` per Mac.
- Unknown keys are ignored.

## 10. Calls

### 10.1 Commands (Mac → phone)

```
ge.connect.dial:<number>
ge.connect.call:decline
ge.connect.call:mute
ge.connect.call:hangup
```

- `dial`: `<number>` consists of digits and `+`, `*`, `#`. The phone **never places the call by
  itself**: it opens the dialer prefilled with the number (or, when the app is in the background,
  shows a heads-up notification that opens it), and the user taps Call on the phone.
- `call:decline`: decline the ringing call.
- `call:mute`: silence the ringer of the ringing call.
- `call:hangup`: end the call in progress, or a ringing one.
- `call:*` commands are ignored when there is no call.

### 10.2 Command results (phone → Mac): `ge.connect.callresult`

| Field | Value |
|---|---|
| `id` | `ge.connect.callresult:<uuid>` |
| `title` | `Call` |
| `text` | `decline:ok`, `decline:failed:<reason>`, `mute:ok`, `hangup:ok` or `hangup:failed:<reason>` |
| `silent` | `true` |

Cancelled after about 10 s.

If the phone cannot decline (no call-control permission, or the system refuses), it **mutes the
ringer instead** and reports `decline:failed:<reason>`. Without the permission it also shows a
notification on the phone that requests it.

### 10.3 Telephony extensions

The phone extends the standard `kdeconnect.telephony` packets:

- When a ringing call is answered, the phone immediately re-sends the `ringing` event with
  `isCancel: true` (stock KDE Connect only does this when the call ends). It then sends a
  `talking` event whose body includes `ge.connect.callStart`: the answer time in epoch ms, by the
  phone's clock.
- When the call ends, the `talking` event is cancelled (stock behaviour).

### 10.4 Call state (phone → Mac): `ge.connect.callstate`

Some engines don't forward `talking` events, telephony cancels or extra fields, so the call state
is also sent as a companion notification:

| Field | Value |
|---|---|
| `id` | `ge.connect.callstate:<call key>`: a key that identifies the call and stays the same for its duration |
| `title` | `Call` |
| `isClearable` | `false` |
| `silent` | `true` |
| `text` | JSON, see below |

```json
{ "state": "ringing" | "talking",
  "number": "<phone number>",
  "name": "<contact name, or empty>",
  "start": <answer time, epoch ms; only with "talking">,
  "now": <phone clock when sent, epoch ms> }
```

Lifecycle:

1. Posted with `ringing` when an incoming call rings.
2. When the call is answered: cancel and repost with the same id, `talking` and `start`.
3. An outgoing call that the phone reports as off-hook is posted directly as `talking`.
4. `isCancel` when the call ends (hung up or missed).

Not subject to the 10 s auto-cancel. To correct for clock offset, a receiver can place the
call's start on its own clock at `start + (receiveTime − now)`.

## 11. Screenshots (`ge.connect.screenshot`)

**Phone → Mac**, right before sharing a new screenshot:

| Field | Value |
|---|---|
| `id` | `ge.connect.screenshot:<uuid>` |
| `title` | `Screenshot` |
| `text` | the file name, exactly as it will be shared |
| `silent` | `true` |

Cancelled after about 10 s. A normal `kdeconnect.share.request` with that file name follows.

The Mac matches the next received file with that name within 2 minutes. A name that the receiver
de-duplicated with a ` (n)` suffix still matches. The Mac then copies the image to the clipboard
and may move it to a chosen folder.

## 12. Live activities (`ge.connect.live`)

Ongoing phone notifications with a timer, progress or ETA (timers, navigation, deliveries, rides,
uploads …) are mirrored as live activities.

### 12.1 Packet

| Field | Value |
|---|---|
| `id` | `ge.connect.live:<stable key>` |
| `silent` | `true` |
| payload | the app's launcher icon, as a standard notification icon payload |
| `text` | JSON, see below |

```json
{ "v": 1,
  "app": "<app label>",
  "title": "<title>",
  "text": "<body text>",
  "short": "<short status text>",
  "progress": 0.42,
  "indeterminate": true,
  "when": 1790000000000,
  "chrono": "up" | "down",
  "cat": "<Android notification category>",
  "icon": "<payloadHash of the icon>",
  "now": 1789999990000 }
```

| Field | Required | Meaning |
|---|---|---|
| `v` | yes | `1`. |
| `app` | yes | Display name of the app that posted the notification. |
| `title`, `text` | yes | May be empty strings. |
| `short` | no | Short status text, for example an ETA range ("15–25 min") or the frozen value of a paused timer. |
| `progress` | no | Fraction from 0.0 to 1.0. |
| `indeterminate` | no | `true` = busy without a known amount; show a spinner or animated bar instead of `progress`. |
| `when` | no | Reference time in epoch ms (phone clock) for a running chronometer. |
| `chrono` | no | `up` = counting up from `when`; `down` = counting down to `when`. |
| `cat` | no | Android notification category (for example `transport`, `alarm`, `progress`). |
| `icon` | no | The `payloadHash` of the launcher icon, so the receiver can use a cached icon when a packet carries no payload. |
| `now` | yes | The phone's clock in epoch ms when the packet was sent. |

### 12.2 Rules

- **Each packet is a complete snapshot.** A missing field is cleared; never merge with the previous
  packet. For example, a paused timer has no `when`/`chrono`, and its frozen value is in `short`.
- **Updates** re-send the same id using cancel and repost ([§3](#3-general-rules)). **End**:
  `isCancel` for the id.
- **Exempt from the 10 s auto-cancel.** All current activities are re-sent after each connect.
- **Clock correction:** the receiver corrects `when` by `(receive time − now)`.
- **Countdowns** stop at 0 on the receiver and wait for the phone's next packet, which will end or
  change the activity.
- **Rate:** pause, resume and a new end time are sent immediately; other changes at most every 2 s
  per activity.
- **Re-keying:** an app may re-key its notifications (for example, a clock app when timers are
  added). An activity can then end and reappear under a new id.

### 12.3 Delivery orders without an ongoing notification

Some delivery and ride-hailing apps post only plain notifications for order progress. For a
built-in list of such apps, the phone turns them into an activity:

- Source: plain notifications on an order-progress channel (a channel id containing `order`,
  `deliver`, `track`, `courier`, `rider` or `trip`, plus known app-specific channel ids).
- **One activity per app:** id `ge.connect.live:order:<package name>`, `cat` = `transport`.
- Each update replaces `title` and `text`.
- ETA parsing from the notification text:
  - a range such as "15–25 min" → `short`
  - a relative time such as "in 15 min" → `when` = post time + 15 min, `chrono` = `down`
  - a clock time such as "at 20:45" or "8:45 PM" (future times only) → `when` at that time,
    `chrono` = `down`
- The activity ends when the text indicates the order was delivered, cancelled or refunded (in
  the languages the phone app recognises), when the app's order notification is cleared or tapped
  and none remain, or after 90 minutes without an update.
- The plain notification is still mirrored as a normal phone notification as well.

## 13. Screen mirroring (`ge.connect.mirror`)

The Mac mirrors the phone's screen over Android **Wireless debugging** (adb over Wi-Fi, for
example with scrcpy). The phone app toggles Wireless debugging itself, which needs
`android.permission.WRITE_SECURE_SETTINGS`. The app declares it, and the Mac grants it once over
adb:

```
adb shell pm grant ge.connect android.permission.WRITE_SECURE_SETTINGS
```

### 13.1 Commands (Mac → phone)

The phone accepts these only from the user's own computers, not from other phones.

| Command | Meaning |
|---|---|
| `ge.connect.mirror:prepare` | Make Wireless debugging ready. Answered with a reply. |
| `ge.connect.mirror:restart` | Restart a stuck Wireless debugging. Answered with a reply. |
| `ge.connect.mirror:started` | Mirroring has started. |
| `ge.connect.mirror:stopped` | Mirroring has stopped. |
| `ge.connect.mirror:done` | The Mac no longer needs Wireless debugging. |
| `ge.connect.mirror:paired` | adb pairing with this phone is complete. |

### 13.2 Replies (phone → Mac)

| Field | Value |
|---|---|
| `id` | `ge.connect.mirror:<uuid>` |
| `title` | `Mirroring` |
| `silent` | `true` |
| `text` | `ready`, `failed:<reason>` or `stop` |

Cancelled after about 10 s.

### 13.3 Behaviour

**`prepare`.** The phone checks, in this order:

1. The permission is granted.
2. Samsung Auto Blocker is off (secure setting `rampart_main_switch_enabled`).
3. Developer options are on.
4. The phone is on Wi-Fi.

A failed check is answered with `failed:<reason>`. If Wireless debugging is already on, the phone
answers `ready` straight away. Otherwise it sets the global setting `adb_wifi_enabled=1` and
answers about 1.5 s later. If Android switched it straight back off, the answer is
`failed:<reason>`. This happens when the current Wi-Fi network has not been allowed yet: Android
then shows its own "Allow wireless debugging on this network?" prompt on the phone. The Mac
should retry after the user has allowed it. Choosing "Always allow on this network" makes later
`prepare`s silent.

**`restart`.** Use this when adbd has died while Wireless debugging is still on (for example, a
USB mode switch on unlock can stop it, and Android only restarts it when the setting changes). The
phone runs the same checks as `prepare`, then sets `adb_wifi_enabled=0`, waits about 500 ms, sets
`=1`, waits about 1.5 s, and replies as for `prepare` (`ready` / `failed:<reason>`). It keeps its
record of who switched Wireless debugging on, and it keeps the mirroring notification as it was.

**`done`.** Wireless debugging is switched back off only if the phone switched it on for this
Mac, and the user's "Keep Wireless debugging on" setting (default off) is off. The phone also does
this automatically when that Mac has been disconnected for 2 minutes.

**`started` / `stopped`.** `started` shows an ongoing phone notification ("Mirroring to
<computer name>") with a timer and a **Stop** button; `stopped` removes it. Tapping Stop sends a
reply with `text` = `stop`. The Mac should then stop mirroring and send `stopped` followed by
`done`. If the notification is still showing 5 s after Stop was tapped, the phone switches
Wireless debugging off itself (even if the user keeps it on, or turned it on) and removes the
notification.

**`paired`.** The phone marks its "Screen mirroring" setup step as done, and remembers this.

## 14. Calendar (`ge.connect.calendar`)

The phone shares its calendars with the user's own computers (not with other phones) when it
has `READ_CALENDAR` permission.

### 14.1 Snapshot (phone → Mac)

| Field | Value |
|---|---|
| `id` | `ge.connect.calendar` (no suffix) |
| `isClearable` | `false` |
| `silent` | `true` |
| `text` | JSON snapshot |

```json
{ "v": 1,
  "now": 1790000000000,
  "from": 1789956800000,
  "to": 1790546400000,
  "calendars": [
    { "id": "3", "name": "Work", "account": "alex@example.com", "color": "#3F51B5" }
  ],
  "events": [
    { "id": "1287:1790006400000",
      "cal": "3",
      "title": "Design review",
      "start": 1790006400000,
      "end": 1790010000000,
      "allDay": false,
      "location": "Room 4",
      "join": "https://meet.example.com/abc-defg-hij",
      "color": "#E67C73" }
  ] }
```

| Field | Meaning |
|---|---|
| `now` | Phone clock when the snapshot was made (epoch ms). |
| `from`, `to` | The window covered: `from` = now − 12 h; `to` = the end of the 7th local day (today + 6 days). |
| `calendars[].id` | Calendar `_ID`, as a string. |
| `calendars[].name`, `.account` | Display name and owning account. |
| `calendars[].color` | `#RRGGBB`. |
| `events[].id` | `<eventId>:<instance begin>`, as a string (unique per occurrence). |
| `events[].cal` | The calendar's `id`. |
| `events[].start`, `.end` | Epoch ms. For all-day events these are the phone's local midnights. |
| `events[].allDay` | Boolean. |
| `events[].location` | Optional. |
| `events[].join` | Optional meeting link, see below. |
| `events[].color` | Optional `#RRGGBB`. Present only when the event has its own colour. |

Content rules:

- Source: `CalendarContract.Instances`, visible and synced calendars only.
- At most 400 occurrences, sorted by start.
- Declined events and cancelled events are left out.
- `join`: the first Google Meet, Zoom, Microsoft Teams or Webex link found in the event's extended
  properties (Google Calendar stores the Meet link there as `hangoutLink`), then in `location`,
  then in the description. Links without a scheme get `https://`.
- All-day events should be interpreted in the phone's time zone (`tz` from the
  [device profile](#15-device-profile-geconnectdevice)).

Delivery rules:

- Every snapshot is complete; it replaces the previous one.
- **Exempt from the 10 s auto-cancel.** Always sent as cancel and repost.
- Sent on connect, about 2 s after calendar provider changes, at local midnight, and on clock or
  time zone changes.
- An unchanged snapshot is not resent. `now` is excluded from that comparison.

### 14.2 Refresh (Mac → phone)

```
ge.connect.calendar:refresh
```

The phone asks Android for an immediate (manual, expedited) sync of every account with visible
synced calendars. It then sends a fresh snapshot right away, even if nothing has changed. Changes
from the sync follow through the normal change path.

### 14.3 Access off

Without `READ_CALENDAR`, a Mac that previously received a snapshot from this phone gets a single:

```json
{ "v": 1, "now": 1790000000000, "calendars": [], "events": [], "off": true }
```

There is no `from`/`to`. Nothing more is sent until access is granted again. Revoking a
permission restarts the Android app, so this snapshot arrives at the next connect. A `refresh`
without access is always answered with it. The permission itself is the on/off switch. A missing
`off` means `false`.

## 15. Device profile (`ge.connect.device`)

The phone describes itself to the user's own computers (not to other phones).

### 15.1 Packet

| Field | Value |
|---|---|
| `id` | `ge.connect.device` (no suffix) |
| `isClearable` | `false` |
| `silent` | `true` |
| `text` | JSON profile |

- **Exempt from the 10 s auto-cancel.** Always sent as cancel and repost.
- Sent after each connect, and about 2 s after a change (language, time zone, configuration,
  wallpaper colours). An unchanged profile is not resent.

```json
{ "v": 1,
  "maker": "Google",
  "brand": "google",
  "model": "Pixel 9",
  "device": "tokay",
  "sdk": 36,
  "release": "16",
  "screen": { "w": 1080, "h": 2424, "dpi": 420, "xdpi": 422.0, "ydpi": 424.0,
              "radius": 110, "cutouts": [[505, 0, 575, 110]] },
  "accent": ["#A8C7FA", "#0B57D0", "#5F6368", "#1F1F1F"],
  "country": "US",
  "tz": "America/New_York",
  "locale": "en-US",
  "app": "1.0",
  "caps": ["status", "ringer", "flashlight", "dnd", "dial", "call", "macstate",
           "macaction", "mirror", "calendar", "live", "device", "notes"] }
```

### 15.2 Fields

| Field | Required | Meaning |
|---|---|---|
| `v` | yes | `1`. |
| `maker` | yes | `Build.MANUFACTURER`. |
| `brand` | yes | `Build.BRAND`. |
| `model` | yes | `Build.MODEL` (for example `SM-S931B` or `Pixel 9`). |
| `device` | yes | `Build.DEVICE`. |
| `market` | no | Marketing name: Samsung's `default_device_name` setting (for example "Galaxy S25"), else `ro.product.marketname`, `ro.product.vendor.marketname` or `ro.config.marketing_name`. Omitted if there is none (Pixels already have a readable `model`). |
| `sdk` | yes | API level (number). |
| `release` | yes | Android version string. |
| `skin` | no | Manufacturer skin and version, for example `One UI 8.0`. |
| `colorCode` | no | Samsung's raw product code from `ril.product_code`, for example `SM-S931BZKDEUB`. The two letters after the model number are the colour code (`ZK` = black). |
| `screen.w`, `screen.h` | yes | Natural portrait size in pixels, at the current display resolution. |
| `screen.dpi` | yes | Density DPI. |
| `screen.xdpi`, `screen.ydpi` | yes | Physical pixels per inch. |
| `screen.radius` | no | Top-left rounded-corner radius in px (Android 12+). |
| `screen.cutouts` | no | Display cutouts as `[left, top, right, bottom]` rectangles in natural portrait px (Android 10+). |
| `accent` | no | Four colours `#RRGGBB`: `system_accent1_200`, `system_accent1_500`, `system_accent2_500`, `system_neutral1_900` (Android 12+). |
| `country` | no | Upper-case region: SIM country, else network country, else locale region. |
| `tz` | yes | IANA time zone id. |
| `locale` | yes | BCP 47 language tag. |
| `app` | yes | Version name of the Android app. |
| `caps` | yes | Companion features the phone implements. |

### 15.3 Capabilities (`caps`)

| Capability | Feature |
|---|---|
| `status` | Status reports and `ge.connect.status` requests ([§8](#8-phone-status-and-toggles-geconnectstatus)) |
| `ringer` | `ge.connect.ringer:*` |
| `flashlight` | `ge.connect.flashlight:*` |
| `dnd` | `ge.connect.dnd:*` and DND reports ([§5](#5-do-not-disturb-geconnectdnd)) |
| `dial` | `ge.connect.dial:*` |
| `call` | `ge.connect.call:*`, call results and call state ([§10](#10-calls)) |
| `macstate` | Understands `ge.connect.macstate` ([§9.3](#93-mac-state-mac--phone)) |
| `macaction` | Understands `ge.connect.macaction` results ([§9.2](#92-action-results-mac--phone)) |
| `mirror` | `ge.connect.mirror:*` ([§13](#13-screen-mirroring-geconnectmirror)) |
| `calendar` | Calendar snapshots ([§14](#14-calendar-geconnectcalendar)) |
| `live` | Live activities ([§12](#12-live-activities-geconnectlive)) |
| `device` | This profile |
| `notes` | Notes sync, including rich notes and attachments ([§16](#16-notes-sync-geconnectnotes), [§17](#17-rich-notes-format)) |

A phone that sends no profile is either an older build or not a Janus app.

### 15.4 Receiver guidance

- Cache the profile per device.
- A display name can be built from `market` (else `model`) plus a colour or OS detail, for
  example "Galaxy S25 · Black" or "Pixel 9 · Android 16".
- Treat a `screen.radius` under 4 % of `screen.w` as missing.
- Interpret all-day calendar events in `tz`.
- Hide features whose capability is missing from `caps`.

## 16. Notes sync (`ge.connect.notes`)

Notes are synced both ways between the phone and each of the user's computers. Every device keeps
a full copy.

### 16.1 Note object

```json
{ "id": "6f1c2e0a-4b8d-4c1e-9a57-2d3b8e9f0c11",
  "rev": "b0a4d7e2-91f3-4c55-8e1a-5c6d7e8f9a0b",
  "text": "Shopping\n- [ ] Milk\n- [x] Bread",
  "pinned": false,
  "created": 1790000000000,
  "modified": 1790000500000,
  "deleted": 1790000900000 }
```

| Field | Meaning |
|---|---|
| `id` | UUID chosen by the side that created the note. |
| `rev` | A new random id on every change (edit, pin, delete, restore). |
| `text` | The note's content. The first line is the title. Formatting is described in [§17](#17-rich-notes-format). |
| `pinned` | Boolean. |
| `created`, `modified` | Whole epoch ms. |
| `deleted` | Optional. When present, the note is a **tombstone**: the time it was deleted (epoch ms). |

Tombstones are kept for 30 days and then purged by each side independently. Checklist items are
stored in the text as `- [ ] ` / `- [x] ` lines.

### 16.2 Wire format

**Mac → phone:** ping command with the JSON appended:

```
ge.connect.notes:{"v":1,"op":"hello"}
```

**Phone → Mac:** companion notification. It uses the normal 10 s auto-cancel.

| Field | Value |
|---|---|
| `id` | `ge.connect.notes:<uuid>` |
| `silent` | `true` |
| `text` | the JSON message |

### 16.3 Operations

```json
{ "v": 1, "op": "hello" }
{ "v": 1, "op": "push",  "notes": [ <note with "base">, … ] }
{ "v": 1, "op": "ack",   "acks":  [ { "id": "<note id>", "rev": "<rev>" }, … ] }
{ "v": 1, "op": "want",  "files": [ "<sha>.<ext>", … ] }
{ "v": 1, "op": "file",  "name": "<sha>.<ext>", "size": <bytes> }
{ "v": 1, "op": "have",  "files": [ "<sha>.<ext>", … ] }
```

`want`, `file` and `have` handle attachments ([§17.8](#178-attachments)). Unknown ops are ignored.

### 16.4 Sync state

Each side keeps, per peer, `acked[peer][id] = rev`: the last revision of each note that this peer
is known to have. A note is **pending** for a peer when its current `rev` differs from
`acked[peer][id]` (or the entry is absent).

### 16.5 Connecting

- The Mac sends `hello` on each connection, only to phones whose `caps` include `notes`.
- The phone pushes to a Mac only after receiving that Mac's `hello` on the current connection.
  It then pushes everything pending.
- A `hello` from the phone is likewise answered with a push of everything pending.
- On `hello`, a side also sends `want` for attachments it is still missing.
- While connected, local changes are pushed about 1 s after editing stops.
- Changes received from one peer are passed on to the other peers.

### 16.6 Push

A `push` contains pending notes. Each note carries an extra field:

- `base` = `acked[peer][id]`: the revision the sender believes the peer has. It is absent if the
  peer has never had the note.

A batch holds at most **50 notes** or about **200 KB of JSON**, whichever limit is reached first.
A note larger than that limit is sent alone in its own batch.

### 16.7 Receiving a note

For each incoming note:

1. **Take it** (store it as received) if any of these hold:
   - we don't have a note with this `id`;
   - our `rev` == incoming `base`;
   - our `rev` == incoming `rev`.
2. Otherwise it is a **conflict**:
   - **Winner:** the version with the larger `modified`. On a tie, the larger `rev`, compared as
     a string. The winner stays under the note's `id`.
   - **Loser:** kept as a **conflict copy**, unless the loser is a tombstone or its `text` equals
     the winner's `text`. The copy has:
     - `id` = name-based UUID version 3 of the UTF-8 bytes of the string
       `conflict:<id>:<losing rev>` (Java's `UUID.nameUUIDFromBytes`, that is MD5 with no
       namespace).
     - `rev` = the losing `rev`.
     - `text`, `pinned`, `created`, `modified` copied from the loser.

     Both sides compute the same copy deterministically, so the copy is not duplicated when it
     syncs.
3. Set `acked[sender][id] = incoming rev`.

After processing the batch, reply with one `ack` that lists `{id, rev}` (the incoming `rev`) for
every note received. If our own version won a conflict, it is still pending for the sender and
is pushed back to it, together with any conflict copy.

### 16.8 Ack

On `ack`, set `acked[peer][id] = rev` for each entry.

## 17. Rich notes format

A note's `text` is Markdown: CommonMark plus GitHub-flavoured strikethrough, task lists and
tables. Sync ([§16](#16-notes-sync-geconnectnotes)) is unaffected. Anything an implementation
doesn't understand must stay in the text untouched. Line breaks are `\n`.

### 17.1 Blocks

| Markdown | Style |
|---|---|
| `# ` text | Title |
| `## ` text | Heading |
| `### ` text | Subheading |
| plain line | Body |
| fenced code block | Monospaced |
| `- ` text | Bulleted list |
| `N. ` text | Numbered list |
| `- [ ] ` / `- [x] ` text | Checklist (unchecked / checked) |
| `> ` text | Quote |

- **Writers** emit only `- ` for bullets and `N. ` for numbers.
- **Readers** also accept `* ` and `+ ` bullets, `N) ` numbers and `[X]` (upper-case) checkboxes,
  and leave them as written.

### 17.2 Nesting

- One tab character (`\t`) per level, placed before any marker (bullet, number, checklist or
  quote).
- A checklist line is therefore: optional tabs, then `- [ ] ` or `- [x] `.
- Numbering restarts on each level. Writers renumber the run of items they edit.

### 17.3 Fenced code

- Fence lines are exactly three backticks. An optional language word after the opening fence is
  kept but ignored.
- Nothing inside a fenced block is formatted: no checkboxes, bullets or inline markup. Return
  doesn't continue lists there.

### 17.4 Inline

| Markdown | Style |
|---|---|
| `**bold**` | bold |
| `*italic*` | italic |
| `~~strike~~` | strikethrough |
| `` `code` `` | inline code |
| `[text](url)` | link |
| bare `http://…` / `https://…` | link |

- A URL that contains spaces or parentheses is written `[text](<url>)`.
- There is no extra escaping layer: Markdown the user types is Markdown.
- CommonMark backslash escapes (`\*`, `\#`, `\|`, …) are respected and displayed without the
  backslash.

### 17.5 Title

- The title is the **first non-empty line**. It is displayed in title style even without `#`.
- For display (note list, widgets, search results, previews), the title is shown without its
  leading `#`s, list/checklist/quote marker and inline markers. The stored text keeps them.

### 17.6 Editing behaviour (recommended for both sides)

- Return at the end of a list item continues the list (numbers count up).
- Return on an empty list item outdents it. At level 0 it ends the list.
- Tab / Shift-Tab (or indent / outdent buttons) nest and un-nest list items.

### 17.7 Tables

GitHub pipe tables:

```
| Item | Qty |
| --- | --- |
| Apples | 3 |
| Pears \| quinces | 2 |
```

- The first line is the first row, followed by the delimiter row `| --- | … |`, then the other rows.
- Every row uses the same form.
- A `|` inside a cell is written `\|`.
- A cell is a single line.

### 17.8 Attachments

**In the text.** An attachment is a line of its own:

```
![name](attachments/<sha>.<ext>)
```

- `<sha>` is the lowercase hex SHA-256 of the file contents.
- `<ext>` is the lowercase file extension, 1–8 characters.
- In `name`, `\` and `]` are escaped with a backslash, and newlines are replaced with spaces.
- Maximum file size: 50 MB.

**Storage.** Each file is stored once per hash. A file that no note references is removed after
30 days. A note in Recently Deleted (a tombstone) still counts as a reference.

**Transfer.** Files travel over the standard KDE Connect share (`kdeconnect.share.request`), with
the file name `<sha>.<ext>`. The notes ops coordinate the transfer:

| Op | When |
|---|---|
| `want` `{"files": […]}` | After receiving a push that references files the receiver doesn't have, and on `hello` for files still missing. |
| `file` `{"name", "size"}` | Sent right before the file is shared under that name. |
| `have` `{"files": […]}` | Sent by the receiver after it has verified the hash of the received file(s). |

- A received share is treated as an attachment if its name matches
  `^[0-9a-f]{64}\.[a-z0-9]{1,8}$` **and** either a `file` op announced that name within the last
  10 minutes or a note references it.
- If the SHA-256 of the received file doesn't match its name, the file is deleted and requested
  again at the next `hello`.
- A `want` is answered one file at a time.
- Attachment transfers show no transfer progress or download notification to the user.

## 18. Quick reference

### Phone → Mac (companion notification `id`)

| `id` | Payload (`text`) | Auto-cancel |
|---|---|---|
| `ge.connect.ping:<uuid>` | message or empty (not silent) | ~10 s |
| `ge.connect.dnd:<uuid>` | `on` \| `off` | ~10 s |
| `ge.connect.transfer:<uuid>` | `<totalBytes>\|<numberOfFiles>` | ~10 s |
| `ge.connect.ring:<uuid>` | `on` \| `off` | ~10 s |
| `ge.connect.status:<uuid>` | `key=value;…` | ~10 s |
| `ge.connect.callresult:<uuid>` | `decline:…` \| `mute:ok` \| `hangup:…` | ~10 s |
| `ge.connect.callstate:<call key>` | JSON | until the call ends |
| `ge.connect.screenshot:<uuid>` | file name | ~10 s |
| `ge.connect.live:<stable key>` | JSON (`v`:1) | until the activity ends |
| `ge.connect.mirror:<uuid>` | `ready` \| `failed:<reason>` \| `stop` | ~10 s |
| `ge.connect.calendar` | JSON (`v`:1) | exempt |
| `ge.connect.device` | JSON (`v`:1) | exempt |
| `ge.connect.notes:<uuid>` | JSON (`v`:1) | ~10 s |

### Mac → phone (ping `message`)

| Message | Reply |
|---|---|
| `ge.connect.dnd:on\|off` | status report |
| `ge.connect.ringer:normal\|vibrate\|silent` | status report |
| `ge.connect.flashlight:on\|off` | status report |
| `ge.connect.status` | status report |
| `ge.connect.macstate:<key=value;…>` | none |
| `ge.connect.macaction:<id>:ok` / `:failed:<reason>` | none |
| `ge.connect.dial:<number>` | none |
| `ge.connect.call:decline\|mute\|hangup` | `ge.connect.callresult` |
| `ge.connect.mirror:prepare\|restart` | `ge.connect.mirror` (`ready` / `failed:…`) |
| `ge.connect.mirror:started\|stopped\|done\|paired` | none |
| `ge.connect.calendar:refresh` | calendar snapshot |
| `ge.connect.notes:<json>` | notes ops |

### Standard packets with Janus semantics

| Packet | Janus behaviour |
|---|---|
| `kdeconnect.findmyphone.request` | A second request while ringing stops the ringing; state reported via `ge.connect.ring`. |
| `kdeconnect.runcommand` | Keys `ge-*` are built-in Mac actions. |
| `kdeconnect.telephony` | `ringing` cancelled on answer; `talking` carries `ge.connect.callStart`. |
| `kdeconnect.share.request` | Preceded by `ge.connect.transfer`, `ge.connect.screenshot` or a notes `file` op where applicable. |
