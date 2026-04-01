# Hold Notifications During Sleep Hours

**Date**: 2026-04-01
**Source**: Session 8 — morning briefing fired at 5am after Tank slept at 4am

## Pattern

Scheduled reminders should respect human sleep patterns. When the scheduler fires during known sleep hours, queue the message as a DM instead of sending a Telegram push notification. DMs wait silently; Telegram buzzes the phone.

## Application

- If Tank went to sleep recently (within 4-6 hours), DM the briefing instead of Telegram
- Morning Telegram briefing should only fire if Tank is likely awake
- Check last DM timestamp — if Tank's last message was a "goodnight" type, hold the push notification

## Related

- feedback_telegram_privacy.md — no fitness stats on Telegram
- Schedule #432 — morning briefing, 9am Bangkok
