import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { CodeBlock } from "../../components/code-block";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "docs.concepts" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
  };
}

export default function ConceptsPage() {
  const t = useTranslations("docs.concepts");

  return (
    <>
      <h1>{t("title")}</h1>
      <p>{t("intro")}</p>

      <h2>{t("hierarchy")}</h2>
      <CodeBlock lang="text">{`Window
  └── Workspace (sidebar entry)
        └── Area (split region)
              └── Tab (terminal, browser, or markdown)`}</CodeBlock>

      <h3>{t("windowTitle")}</h3>
      <p>
        {t("windowDesc", { shortcut: "⌘⇧N" })}
      </p>

      <h3>{t("workspaceTitle")}</h3>
      <p>{t("workspaceDesc")}</p>
      <p>
        <strong>
          {t("workspaceShortcuts", {
            new: "⌘N",
            jump: "⌘1–⌘9",
            close: "⌘⇧W",
            prevNext: "⌘⇧[ / ⌘⇧]",
          })}
        </strong>
      </p>

      <h3>{t("areaTitle")}</h3>
      <p>
        {t("areaDesc", {
          right: "⌘D",
          down: "⌘⇧D",
          nav: "⌥⌘",
        })}
      </p>
      <p>{t("areaNote")}</p>

      <h3>{t("tabTitle")}</h3>
      <p>
        {t("tabDesc", {
          new: "⌘T",
          prev: "⌘[",
          next: "⌘]",
          jump: "⌃1–⌃9",
        })}
      </p>
      <p>{t("tabNote")}</p>

      <h2>{t("visualExample")}</h2>
      <CodeBlock variant="ascii">{`┌──────────────────────────────────────────────────────┐
│ ┌──────────┐ ┌─────────────────────────────────────┐ │
│ │ Sidebar  │ │ Workspace "dev"                     │ │
│ │          │ │                                     │ │
│ │          │ │ ┌───────────────┬─────────────────┐ │ │
│ │ > dev    │ │ │ Area 1        │ Area 2          │ │ │
│ │   server │ │ │ [T1] [T2]     │ [T1]            │ │ │
│ │   logs   │ │ │               │                 │ │ │
│ │          │ │ │  Terminal     │  Terminal       │ │ │
│ │          │ │ │               │                 │ │ │
│ │          │ │ └───────────────┴─────────────────┘ │ │
│ └──────────┘ └─────────────────────────────────────┘ │
└──────────────────────────────────────────────────────┘`}</CodeBlock>
      <p>{t("visualExampleDesc")}</p>
      <ul>
        <li>{t("visualItem1")}</li>
        <li>{t("visualItem2")}</li>
        <li>{t("visualItem3")}</li>
        <li>{t("visualItem4")}</li>
      </ul>

      <h2>{t("summary")}</h2>
      <table>
        <thead>
          <tr>
            <th>{t("levelHeader")}</th>
            <th>{t("whatItIsHeader")}</th>
            <th>{t("createdByHeader")}</th>
            <th>{t("identifiedByHeader")}</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td>{t("windowTitle")}</td>
            <td>{t("macosWindow")}</td>
            <td>
              <code>⌘⇧N</code>
            </td>
            <td>—</td>
          </tr>
          <tr>
            <td>{t("workspaceTitle")}</td>
            <td>{t("sidebarEntry")}</td>
            <td>
              <code>⌘N</code>
            </td>
            <td>
              <code>C11_WORKSPACE_ID</code>
            </td>
          </tr>
          <tr>
            <td>{t("areaTitle")}</td>
            <td>{t("splitRegion")}</td>
            <td>
              <code>⌘D</code> / <code>⌘⇧D</code>
            </td>
            <td>{t("areaIdSocket")}</td>
          </tr>
          <tr>
            <td>{t("tabTitle")}</td>
            <td>{t("tabWithinArea")}</td>
            <td>
              <code>⌘T</code>
            </td>
            <td>
              <code>C11_TAB_ID</code>
            </td>
          </tr>
        </tbody>
      </table>
    </>
  );
}
