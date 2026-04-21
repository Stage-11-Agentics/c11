import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { CodeBlock } from "../../components/code-block";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "docs.browserAutomation" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
  };
}

export default function BrowserAutomationPage() {
  const t = useTranslations("docs.browserAutomation");

  return (
    <>
      <h1>{t("title")}</h1>
      <p>{t("intro")}</p>

      <h2>{t("commandIndex")}</h2>
      <table>
        <thead>
          <tr>
            <th>{t("categoryHeader")}</th>
            <th>{t("subcommandsHeader")}</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td>{t("navAndTargeting")}</td>
            <td>
              <code>identify</code>, <code>open</code>, <code>open-split</code>,{" "}
              <code>navigate</code>, <code>back</code>, <code>forward</code>,{" "}
              <code>reload</code>, <code>url</code>, <code>focus-webview</code>,{" "}
              <code>is-webview-focused</code>
            </td>
          </tr>
          <tr>
            <td>{t("waiting")}</td>
            <td>
              <code>wait</code>
            </td>
          </tr>
          <tr>
            <td>{t("domInteraction")}</td>
            <td>
              <code>click</code>, <code>dblclick</code>, <code>hover</code>,{" "}
              <code>focus</code>, <code>check</code>, <code>uncheck</code>,{" "}
              <code>scroll-into-view</code>, <code>type</code>, <code>fill</code>,{" "}
              <code>press</code>, <code>keydown</code>, <code>keyup</code>,{" "}
              <code>select</code>, <code>scroll</code>
            </td>
          </tr>
          <tr>
            <td>{t("inspection")}</td>
            <td>
              <code>snapshot</code>, <code>screenshot</code>, <code>get</code>,{" "}
              <code>is</code>, <code>find</code>, <code>highlight</code>
            </td>
          </tr>
          <tr>
            <td>{t("jsAndInjection")}</td>
            <td>
              <code>eval</code>, <code>addinitscript</code>, <code>addscript</code>,{" "}
              <code>addstyle</code>
            </td>
          </tr>
          <tr>
            <td>{t("framesDialogsDownloads")}</td>
            <td>
              <code>frame</code>, <code>dialog</code>, <code>download</code>
            </td>
          </tr>
          <tr>
            <td>{t("stateAndSession")}</td>
            <td>
              <code>cookies</code>, <code>storage</code>, <code>state</code>
            </td>
          </tr>
          <tr>
            <td>{t("tabsAndLogs")}</td>
            <td>
              <code>tab</code>, <code>console</code>, <code>errors</code>
            </td>
          </tr>
        </tbody>
      </table>

      <h2>{t("targetingSurface")}</h2>
      <p>{t("targetingDesc")}</p>
      <CodeBlock lang="bash">{`# Open a new browser split
c11 browser open https://example.com

# Discover focused IDs and browser metadata
c11 browser identify
c11 browser identify --surface surface:2

# Positional vs flag targeting are equivalent
c11 browser surface:2 url
c11 browser --surface surface:2 url`}</CodeBlock>

      <h2>{t("navigation")}</h2>
      <CodeBlock lang="bash">{`c11 browser open https://example.com
c11 browser open-split https://news.ycombinator.com

c11 browser surface:2 navigate https://example.org/docs --snapshot-after
c11 browser surface:2 back
c11 browser surface:2 forward
c11 browser surface:2 reload --snapshot-after
c11 browser surface:2 url

c11 browser surface:2 focus-webview
c11 browser surface:2 is-webview-focused`}</CodeBlock>

      <h2>{t("waitingSection")}</h2>
      <p>{t("waitingDesc")}</p>
      <CodeBlock lang="bash">{`c11 browser surface:2 wait --load-state complete --timeout-ms 15000
c11 browser surface:2 wait --selector "#checkout" --timeout-ms 10000
c11 browser surface:2 wait --text "Order confirmed"
c11 browser surface:2 wait --url-contains "/dashboard"
c11 browser surface:2 wait --function "window.__appReady === true"`}</CodeBlock>

      <h2>{t("domSection")}</h2>
      <p>{t("domDesc")}</p>
      <CodeBlock lang="bash">{`c11 browser surface:2 click "button[type='submit']" --snapshot-after
c11 browser surface:2 dblclick ".item-row"
c11 browser surface:2 hover "#menu"
c11 browser surface:2 focus "#email"
c11 browser surface:2 check "#terms"
c11 browser surface:2 uncheck "#newsletter"
c11 browser surface:2 scroll-into-view "#pricing"

c11 browser surface:2 type "#search" "cmux"
c11 browser surface:2 fill "#email" --text "ops@example.com"
c11 browser surface:2 fill "#email" --text ""
c11 browser surface:2 press Enter
c11 browser surface:2 keydown Shift
c11 browser surface:2 keyup Shift
c11 browser surface:2 select "#region" "us-east"
c11 browser surface:2 scroll --dy 800 --snapshot-after
c11 browser surface:2 scroll --selector "#log-view" --dx 0 --dy 400`}</CodeBlock>

      <h2>{t("inspectionSection")}</h2>
      <p>{t("inspectionDesc")}</p>
      <CodeBlock lang="bash">{`c11 browser surface:2 snapshot --interactive --compact
c11 browser surface:2 snapshot --selector "main" --max-depth 5
c11 browser surface:2 screenshot --out /tmp/cmux-page.png

c11 browser surface:2 get title
c11 browser surface:2 get url
c11 browser surface:2 get text "h1"
c11 browser surface:2 get html "main"
c11 browser surface:2 get value "#email"
c11 browser surface:2 get attr "a.primary" --attr href
c11 browser surface:2 get count ".row"
c11 browser surface:2 get box "#checkout"
c11 browser surface:2 get styles "#total" --property color

c11 browser surface:2 is visible "#checkout"
c11 browser surface:2 is enabled "button[type='submit']"
c11 browser surface:2 is checked "#terms"

c11 browser surface:2 find role button --name "Continue"
c11 browser surface:2 find text "Order confirmed"
c11 browser surface:2 find label "Email"
c11 browser surface:2 find placeholder "Search"
c11 browser surface:2 find alt "Product image"
c11 browser surface:2 find title "Open settings"
c11 browser surface:2 find testid "save-btn"
c11 browser surface:2 find first ".row"
c11 browser surface:2 find last ".row"
c11 browser surface:2 find nth 2 ".row"

c11 browser surface:2 highlight "#checkout"`}</CodeBlock>

      <h2>{t("jsSection")}</h2>
      <CodeBlock lang="bash">{`c11 browser surface:2 eval "document.title"
c11 browser surface:2 eval --script "window.location.href"

c11 browser surface:2 addinitscript "window.__cmuxReady = true;"
c11 browser surface:2 addscript "document.querySelector('#name')?.focus()"
c11 browser surface:2 addstyle "#debug-banner { display: none !important; }"`}</CodeBlock>

      <h2>{t("stateSection")}</h2>
      <p>{t("stateDesc")}</p>
      <CodeBlock lang="bash">{`c11 browser surface:2 cookies get
c11 browser surface:2 cookies get --name session_id
c11 browser surface:2 cookies set session_id abc123 --domain example.com --path /
c11 browser surface:2 cookies clear --name session_id
c11 browser surface:2 cookies clear --all

c11 browser surface:2 storage local set theme dark
c11 browser surface:2 storage local get theme
c11 browser surface:2 storage local clear
c11 browser surface:2 storage session set flow onboarding
c11 browser surface:2 storage session get flow

c11 browser surface:2 state save /tmp/cmux-browser-state.json
c11 browser surface:2 state load /tmp/cmux-browser-state.json`}</CodeBlock>

      <h2>{t("tabsSection")}</h2>
      <p>{t("tabsDesc")}</p>
      <CodeBlock lang="bash">{`c11 browser surface:2 tab list
c11 browser surface:2 tab new https://example.com/pricing

# Switch by index or by target surface
c11 browser surface:2 tab switch 1
c11 browser surface:2 tab switch surface:7

# Close current tab or a specific target
c11 browser surface:2 tab close
c11 browser surface:2 tab close surface:7`}</CodeBlock>

      <h2>{t("consoleSection")}</h2>
      <CodeBlock lang="bash">{`c11 browser surface:2 console list
c11 browser surface:2 console clear

c11 browser surface:2 errors list
c11 browser surface:2 errors clear`}</CodeBlock>

      <h2>{t("dialogsSection")}</h2>
      <CodeBlock lang="bash">{`c11 browser surface:2 dialog accept
c11 browser surface:2 dialog accept "Confirmed by automation"
c11 browser surface:2 dialog dismiss`}</CodeBlock>

      <h2>{t("framesSection")}</h2>
      <CodeBlock lang="bash">{`# Enter an iframe context
c11 browser surface:2 frame "iframe[name='checkout']"
c11 browser surface:2 click "#pay-now"

# Return to the top-level document
c11 browser surface:2 frame main`}</CodeBlock>

      <h2>{t("downloadsSection")}</h2>
      <CodeBlock lang="bash">{`c11 browser surface:2 click "a#download-report"
c11 browser surface:2 download --path /tmp/report.csv --timeout-ms 30000`}</CodeBlock>

      <h2>{t("commonPatterns")}</h2>

      <h3>{t("patternNavigate")}</h3>
      <CodeBlock lang="bash">{`c11 browser open https://example.com/login
c11 browser surface:2 wait --load-state complete --timeout-ms 15000
c11 browser surface:2 snapshot --interactive --compact
c11 browser surface:2 get title`}</CodeBlock>

      <h3>{t("patternForm")}</h3>
      <CodeBlock lang="bash">{`c11 browser surface:2 fill "#email" --text "ops@example.com"
c11 browser surface:2 fill "#password" --text "$PASSWORD"
c11 browser surface:2 click "button[type='submit']" --snapshot-after
c11 browser surface:2 wait --text "Welcome"
c11 browser surface:2 is visible "#dashboard"`}</CodeBlock>

      <h3>{t("patternDebug")}</h3>
      <CodeBlock lang="bash">{`c11 browser surface:2 console list
c11 browser surface:2 errors list
c11 browser surface:2 screenshot --out /tmp/cmux-failure.png
c11 browser surface:2 snapshot --interactive --compact`}</CodeBlock>

      <h3>{t("patternSession")}</h3>
      <CodeBlock lang="bash">{`c11 browser surface:2 state save /tmp/session.json
# ...later...
c11 browser surface:2 state load /tmp/session.json
c11 browser surface:2 reload`}</CodeBlock>
    </>
  );
}
