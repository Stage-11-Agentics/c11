import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { CodeBlock } from "../../components/code-block";
import { Callout } from "../../components/callout";
import { DownloadButton } from "../../components/download-button";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "docs.gettingStarted" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
  };
}

export default function GettingStartedPage() {
  const t = useTranslations("docs.gettingStarted");

  return (
    <>
      <h1>{t("title")}</h1>
      <p>{t("intro")}</p>

      <h2>{t("install")}</h2>

      <h3>{t("dmgRecommended")}</h3>
      <div className="my-4">
        <DownloadButton />
      </div>
      <p>{t("dmgDesc")}</p>

      <h3>{t("homebrew")}</h3>
      <CodeBlock lang="bash">{`brew tap stage-11-agentics/c11
brew install --cask c11`}</CodeBlock>
      <p>{t("updateLater")}</p>
      <CodeBlock lang="bash">{`brew upgrade --cask c11`}</CodeBlock>

      <Callout>
        {t.rich("firstLaunchCallout", {
          strong: (chunks) => <strong>{chunks}</strong>,
        })}
      </Callout>

      <h2>{t("verifyTitle")}</h2>
      <p>{t("verifyDesc")}</p>
      <ul>
        <li>{t("verifyItem1")}</li>
        <li>{t("verifyItem2")}</li>
        <li>{t("verifyItem3")}</li>
      </ul>

      <h2>{t("cliSetup")}</h2>
      <p>{t("cliDesc")}</p>
      <CodeBlock lang="bash">{`sudo ln -sf "/Applications/c11.app/Contents/Resources/bin/c11" /usr/local/bin/c11`}</CodeBlock>
      <p>{t("cliThen")}</p>
      <CodeBlock lang="bash">{`c11 list-workspaces
c11 notify --title "Build Complete" --body "Your build finished"`}</CodeBlock>

      <h2>{t("autoUpdates")}</h2>
      <p>{t("autoUpdatesDesc")}</p>

      <h2>{t("sessionRestore")}</h2>
      <p>{t("sessionRestoreDesc")}</p>
      <ul>
        <li>{t("sessionItem1")}</li>
        <li>{t("sessionItem2")}</li>
        <li>{t("sessionItem3")}</li>
        <li>{t("sessionItem4")}</li>
      </ul>
      <Callout>{t("sessionCallout")}</Callout>

      <h2>{t("requirements")}</h2>
      <ul>
        <li>{t("reqItem1")}</li>
        <li>{t("reqItem2")}</li>
      </ul>
    </>
  );
}
