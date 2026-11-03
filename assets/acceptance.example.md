# Acceptance contract: email to task (example)

Task: in the unified workspace, a user connects Gmail and turns an email into a task.

## Criteria

- AC1 :: a signed-in user connects Gmail and the settings page shows "Connected" :: e2e :: run: npx playwright test tests/proof/gmail-connect.spec.ts
- AC2 :: POST /api/emails/:id/to-task creates one task with the email subject as title :: integration :: run: pytest tests/test_email_to_task.py -q
- AC3 :: converting the same email twice creates only one task :: integration :: run: pytest tests/test_email_to_task.py -q -k idempotent
- AC4 :: the inbox shows the new task at the top without a reload, no console error :: e2e :: run: npx playwright test tests/proof/inbox-convert.spec.ts
- AC5 :: the inbox after converting one email, at 390 px and 1440 px :: visual :: see: two screenshots, task visible at the top
- AC6 :: the bug "subject with an emoji crashes the conversion" is fixed :: unit :: run: pytest tests/test_subject_parsing.py -q -k emoji
- AC7 :: the build succeeds :: static :: run: npm run build
- AC8 :: the feature works on staging :: runtime :: run: curl -fsS https://staging.example.com/api/health | grep -q '"version":"1.4.0"'

## Out of scope

- Outlook and other providers
- Converting attachments
- Mobile app
