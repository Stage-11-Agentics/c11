export interface ChangelogSection {
  heading: string;
  items: string[];
}

export interface ChangelogVersion {
  version: string;
  date: string;
  intro?: string;
  sections: ChangelogSection[];
}

export function parseChangelog(markdown: string): ChangelogVersion[] {
  const versions: ChangelogVersion[] = [];
  let current: ChangelogVersion | null = null;
  let currentSection: ChangelogSection | null = null;

  for (const line of markdown.split("\n")) {
    const versionMatch = line.match(/^## \[(.+?)\] - (.+)$/);
    if (versionMatch) {
      if (current) versions.push(current);
      current = {
        version: versionMatch[1],
        date: versionMatch[2],
        sections: [],
      };
      currentSection = null;
      continue;
    }

    if (!current) continue;

    const sectionMatch = line.match(/^### (.+)$/);
    if (sectionMatch) {
      currentSection = { heading: sectionMatch[1], items: [] };
      current.sections.push(currentSection);
      continue;
    }

    const subitemMatch = line.match(/^(\s+)- (.+)$/);
    if (subitemMatch && currentSection?.items.length) {
      const lastItemIndex = currentSection.items.length - 1;
      currentSection.items[lastItemIndex] += `\n${subitemMatch[2]}`;
      continue;
    }

    const itemMatch = line.match(/^- (.+)$/);
    if (itemMatch) {
      if (currentSection) {
        currentSection.items.push(itemMatch[1]);
      } else {
        if (!current.sections.length) {
          currentSection = { heading: "", items: [] };
          current.sections.push(currentSection);
        }
        current.sections[current.sections.length - 1].items.push(
          itemMatch[1]
        );
      }
      continue;
    }

    const trimmed = line.trim();
    if (trimmed.startsWith("|")) continue;
    if (!trimmed || trimmed.startsWith("#")) continue;

    const headlineMatch = trimmed.match(/^Headline:\s*(.+)$/);
    if (headlineMatch) {
      current.intro = headlineMatch[1].replace(/^\*\*(.*)\*\*$/, "$1");
    } else if (currentSection) {
      currentSection.items.push(trimmed);
    } else if (!current.intro) {
      current.intro = trimmed;
    }
  }

  if (current) versions.push(current);
  return versions;
}
