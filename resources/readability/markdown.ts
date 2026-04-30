import { unified } from "npm:unified@11.0.5";
import rehypeParse from "npm:rehype-parse@9.0.1";
import rehypeRemark from "npm:rehype-remark@10.0.1";
import remarkGfm from "npm:remark-gfm@4.0.1";
import remarkStringify from "npm:remark-stringify@11.0.0";

type HastNode = {
  type?: string;
  tagName?: string;
  value?: string;
  properties?: Record<string, unknown>;
  children?: HastNode[];
};

function propText(props: Record<string, unknown>, name: string): string {
  const value = props[name];
  if (value === undefined || value === null || value === false) return "";
  if (Array.isArray(value)) return value.join(" ");
  if (value === true) return name;
  return String(value);
}

function nodeText(node: HastNode): string {
  if (node.type === "text") return node.value || "";
  return (node.children || []).map(nodeText).join("").trim();
}

function attrs(props: Record<string, unknown>, names: string[]): string {
  const parts: string[] = [];
  for (const name of names) {
    const value = propText(props, name);
    if (value) parts.push(`${name}="${value.replace(/"/g, "&quot;")}"`);
  }
  return parts.length ? " " + parts.join(" ") : "";
}

function refAttr(props: Record<string, unknown>): string {
  const ref = propText(props, "dataNcdpRef") ||
    propText(props, "data-ncdp-ref") ||
    propText(props, "ref");
  return ref ? ` ref="${ref.replace(/"/g, "&quot;")}"` : "";
}

function describeControl(node: HastNode): string | undefined {
  // rehype-remark otherwise flattens controls to ambiguous text like
  // "Email AdaSend". Emit compact, machine-readable descriptions instead.
  const props = node.properties || {};
  switch (node.tagName) {
    case "input": {
      const type = propText(props, "type") || "text";
      const checked = props.checked ? " checked" : "";
      return `[input${refAttr(props)} type="${type}"${attrs(props, ["name", "value", "placeholder"])}${checked}]`;
    }
    case "textarea":
      return `[textarea${refAttr(props)}${attrs(props, ["name", "placeholder"])} value="${nodeText(node).replace(/"/g, "&quot;")}"]`;
    case "select": {
      const options = (node.children || [])
        .filter(child => child.type === "element" && child.tagName === "option")
        .map(option => {
          const text = nodeText(option);
          return option.properties?.selected ? `${text} (selected)` : text;
        })
        .filter(Boolean)
        .join(", ");
      return `[select${refAttr(props)}${attrs(props, ["name"])} options="${options.replace(/"/g, "&quot;")}"]`;
    }
    case "button":
      return `[button${refAttr(props)}${attrs(props, ["type", "name", "value"])} text="${nodeText(node).replace(/"/g, "&quot;")}"]`;
    default:
      return undefined;
  }
}

function preserveFormControls() {
  // Run as a rehype plugin before converting HAST to MDAST so form controls are
  // represented as inline code spans rather than being lost during conversion.
  return (tree: HastNode) => {
    const visit = (node: HastNode) => {
      if (!node.children) return;
      node.children = node.children.map(child => {
        if (child.type === "element") {
          const description = describeControl(child);
          if (description) {
            return {
              type: "element",
              tagName: "code",
              properties: {},
              children: [{ type: "text", value: description }],
            };
          }
          visit(child);
        }
        return child;
      });
    };
    visit(tree);
  };
}

function annotateLinkRefs() {
  return (tree: HastNode) => {
    const visit = (node: HastNode) => {
      if (node.type === "element" && node.tagName === "a") {
        const ref = refAttr(node.properties || {}).trim()
          .replace(/^ref="/, "")
          .replace(/"$/, "");
        if (ref) {
          node.children ||= [];
          node.children.push({ type: "text", value: ` (ref=${ref})` });
        }
      }
      for (const child of node.children || []) visit(child);
    };
    visit(tree);
  };
}

function htmlToMarkdown(html: string): string {
  const file = unified()
    .use(rehypeParse, { fragment: true })
    .use(annotateLinkRefs)
    .use(preserveFormControls)
    .use(rehypeRemark)
    .use(remarkGfm)
    .use(remarkStringify, {
      bullet: "-",
      fences: true,
      rule: "-",
    })
    .processSync(html);

  return String(file).trim();
}

(globalThis as Record<string, unknown>).__ncdpHtmlToMarkdown = htmlToMarkdown;
