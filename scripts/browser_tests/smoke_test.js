// smoke_test.js
// Playwright smoke tests for phronomy-examples Rails apps.
//
// Environment variables:
//   APP_NAME    — one of: 09_rails_chat, 15_rails_secure_chat, 18_rails_agent_job, 20_cve_scanner
//   VERIFY_PORT — port number the Rails server is listening on
//
// Exit code: 0 = all checks passed, 1 = one or more checks failed.

'use strict';

const { chromium } = require('playwright');

const APP_NAME = process.env.APP_NAME;
const PORT     = process.env.VERIFY_PORT;
const BASE     = `http://localhost:${PORT}`;

// ── Per-app test functions ────────────────────────────────────────────────────

/**
 * 09_rails_chat & 15_rails_secure_chat share the same view structure:
 *   - Root page shows a "New Chat" button (no thread_id yet)
 *   - Clicking "New Chat" POSTs to /conversations and redirects back
 *   - After redirect the chat input (#chat-input) and Send button appear
 *
 * 09_rails_chat additionally exercises the real Agent → LLM → SQLite
 * Persistence consumer path and then reloads the page to verify durable
 * transcript read-back.
 */
async function testConversationApp(page) {
  // 1. Load root page
  await page.goto(BASE, { waitUntil: 'domcontentloaded', timeout: 15000 });
  const title = await page.title();
  console.log(`    page title: "${title}"`);

  // 2. "New Chat" button must be visible
  const newChatBtn = page.locator('button:has-text("New Chat")');
  await newChatBtn.waitFor({ state: 'visible', timeout: 5000 });
  console.log('    "New Chat" button visible');

  // 3. Click → server creates a conversation, redirects back
  await Promise.all([
    page.waitForNavigation({ waitUntil: 'domcontentloaded', timeout: 15000 }),
    newChatBtn.click(),
  ]);

  // 4. After redirect, chat input must appear
  const chatInput = page.locator('#chat-input');
  await chatInput.waitFor({ state: 'visible', timeout: 5000 });
  console.log('    #chat-input visible after "New Chat"');

  // 5. Send button must be visible
  const sendBtn = page.locator('button[type="submit"]:has-text("Send")');
  await sendBtn.waitFor({ state: 'visible', timeout: 5000 });
  console.log('    "Send" button visible');

  if (APP_NAME !== '09_rails_chat') return;

  // 6. Exercise the actual Rails consumer path:
  //    MessagesController → ChatAgent.load → Agent#invoke → LLM → Persistence.
  const prompt = `Persistence smoke ${Date.now()}: reply in one short sentence.`;
  const assistantSelector =
    '#messages > div.flex.justify-start:not(#thinking) > div';
  const assistantCountBefore =
    await page.locator(assistantSelector).count();

  await chatInput.fill(prompt);
  await sendBtn.click();
  console.log('    sent real Agent/LLM persistence smoke message');

  // Wait for either a new assistant bubble or a rendered application error.
  const outcomeHandle = await page.waitForFunction(
    ({ selector, before }) => {
      const assistants = document.querySelectorAll(selector);
      if (assistants.length > before) {
        return { kind: 'reply' };
      }

      const error = document.querySelector('#error-msg');
      if (error && !error.classList.contains('hidden')) {
        return {
          kind: 'error',
          text: (error.textContent || '').trim(),
        };
      }

      return false;
    },
    { selector: assistantSelector, before: assistantCountBefore },
    { timeout: 240000 }
  );
  const outcome = await outcomeHandle.jsonValue();

  if (outcome.kind === 'error') {
    throw new Error(`09_rails_chat LLM request failed: ${outcome.text}`);
  }

  const assistantBubbles = page.locator(assistantSelector);
  const assistantText =
    (await assistantBubbles.last().innerText()).trim();
  if (!assistantText) {
    throw new Error('09_rails_chat returned an empty assistant message');
  }
  console.log(`    assistant reply received (${assistantText.length} chars)`);

  // 7. A GET / after the LLM request constructs a fresh ChatAgent instance via
  //    ChatAgent.load. Verify the same transcript is read back from SQLite.
  await page.reload({ waitUntil: 'domcontentloaded', timeout: 15000 });

  await page.getByText(prompt, { exact: true })
    .waitFor({ state: 'visible', timeout: 5000 });

  const reloadedAssistantText =
    (await page.locator(assistantSelector).last().innerText()).trim();

  if (reloadedAssistantText !== assistantText) {
    throw new Error(
      '09_rails_chat assistant transcript changed after durable reload'
    );
  }

  console.log('    durable user/assistant transcript survived page reload');
}

/**
 * 18_rails_agent_job: root page immediately shows a text input and Send button.
 * No "New Chat" step is needed — the session_id is auto-generated on GET /.
 */
async function testAgentJobApp(page) {
  // 1. Load root page
  await page.goto(BASE, { waitUntil: 'domcontentloaded', timeout: 15000 });
  const title = await page.title();
  console.log(`    page title: "${title}"`);

  // 2. H1 heading must be visible
  const h1 = page.locator('h1').first();
  await h1.waitFor({ state: 'visible', timeout: 5000 });
  const h1Text = await h1.innerText();
  console.log(`    h1: "${h1Text.trim()}"`);

  // 3. Message input (#message-input)
  const input = page.locator('#message-input');
  await input.waitFor({ state: 'visible', timeout: 5000 });
  console.log('    #message-input visible');

  // 4. Send button
  const sendBtn = page.locator('button[type="submit"]:has-text("Send")');
  await sendBtn.waitFor({ state: 'visible', timeout: 5000 });
  console.log('    "Send" button visible');
}

/**
 * 20_cve_scanner: root page shows a CVE ID textarea and a "Start Scan" button.
 * Always runs a full scan end-to-end using mock mode (CVE_SCANNER_MOCK_LLM=1
 * must be set on the Rails server — verify_examples.sh handles this automatically):
 *   enter CVE ID → start scan → wait for awaiting_followup → send "done" → verify completion.
 */
async function testCveScannerApp(page) {
  // 1. Load root page
  await page.goto(BASE, { waitUntil: 'domcontentloaded', timeout: 15000 });
  const title = await page.title();
  console.log(`    page title: "${title}"`);

  // 2. H1 heading must contain "CVE Scanner"
  const h1 = page.locator('h1').first();
  await h1.waitFor({ state: 'visible', timeout: 5000 });
  const h1Text = await h1.innerText();
  console.log(`    h1: "${h1Text.trim()}"`);

  // 3. CVE input textarea (#cve-input) must be visible
  const cveInput = page.locator('#cve-input');
  await cveInput.waitFor({ state: 'visible', timeout: 5000 });
  console.log('    #cve-input visible');

  // 4. "Start Scan" button must be visible
  const scanBtn = page.locator('#scan-btn');
  await scanBtn.waitFor({ state: 'visible', timeout: 5000 });
  console.log('    #scan-btn visible');

  // 5. Enter a CVE ID and start the scan
  await cveInput.fill('CVE-2024-1234');
  console.log('    filled #cve-input with "CVE-2024-1234"');

  await scanBtn.click();
  console.log('    clicked #scan-btn');

  // 6. Pipeline log card should appear immediately (startScan() shows it synchronously)
  const logCard = page.locator('#log-card');
  await logCard.waitFor({ state: 'visible', timeout: 10000 });
  console.log('    #log-card visible (scan started)');

  // 7. Wait for awaiting_followup state — #chat-input-bar becomes visible.
  //    Generous timeout: the Ubuntu CVE scraper has up to 20 s read_timeout;
  //    mock LLM agent calls are instant once the HTTP fetch completes.
  const chatInputBar = page.locator('#chat-input-bar');
  await chatInputBar.waitFor({ state: 'visible', timeout: 90000 });
  console.log('    #chat-input-bar visible (awaiting_followup reached)');

  // 8. The server runs with CVE_SCANNER_MOCK_LLM=1 so CveAnalystAgent returns
  //    decision:"done" immediately — graph must NOT halt at awaiting_check_approval.
  //    Verify that no approval card was rendered.
  const approvalInline = page.locator('#approval-inline');
  const approvalVisible = await approvalInline.isVisible().catch(() => false);
  if (approvalVisible) {
    throw new Error('#approval-inline visible in mock mode — check/remediation approval was NOT skipped');
  }
  console.log('    #approval-inline absent (mock correctly skipped approval)');

  // 9. Type "done" to end the session. "done" matches DONE_KEYWORDS on the
  //    server side, so the FollowupAgent short-circuits without an LLM call.
  const chatBarInput = page.locator('#chat-bar-input');
  await chatBarInput.fill('done');
  console.log('    filled #chat-bar-input with "done"');

  await page.locator('#chat-bar-send').click();
  console.log('    clicked #chat-bar-send');

  // 10. The followup_answer handler (decision:"done") re-enables #scan-btn
  //     and hides #chat-input-bar — use that as the completion signal.
  await page.locator('#scan-btn:not([disabled])').waitFor({ timeout: 30000 });
  console.log('    #scan-btn re-enabled (scan completed)');

  const statusText = await page.locator('#status-line').innerText().catch(() => '');
  console.log(`    status-line: "${statusText.trim()}"`);
}

// ── Test registry ─────────────────────────────────────────────────────
const TESTS = {
  '09_rails_chat':        testConversationApp,
  '15_rails_secure_chat': testConversationApp,
  '18_rails_agent_job':   testAgentJobApp,
  '20_cve_scanner':       testCveScannerApp,
};

// ── Runner ─────────────────────────────────────────────────────────────────────
(async () => {
  if (!APP_NAME || !PORT) {
    console.error('Usage: APP_NAME=<name> VERIFY_PORT=<port> node smoke_test.js');
    process.exit(1);
  }

  const testFn = TESTS[APP_NAME];
  if (!testFn) {
    console.error(`Unknown app: "${APP_NAME}". Valid values: ${Object.keys(TESTS).join(', ')}`);
    process.exit(1);
  }

  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext();
  const page    = await context.newPage();

  // Log any JS console errors on the page.
  page.on('console', (msg) => {
    if (msg.type() === 'error') {
      console.log(`    [JS error] ${msg.text()}`);
    }
  });

  let failed = false;
  try {
    await testFn(page);
    console.log(`  [PASS] Playwright smoke test for ${APP_NAME}`);
  } catch (e) {
    console.error(`  [FAIL] ${e.message}`);
    failed = true;
  } finally {
    await browser.close();
  }

  process.exit(failed ? 1 : 0);
})();
