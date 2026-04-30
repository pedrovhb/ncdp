## ARIA snapshot and ref-action helpers for AI-friendly page interaction.

import std/[json, options, sequtils, strutils]
import chronos
import cdp/gen/input as cdpInput
import ./browser

const AriaHelperSource = staticRead("../../examples/ariaSnapshot.js")
const ReadabilitySource = staticRead("../../resources/readability/Readability.js")
const MarkdownSource = staticRead("../../resources/readability/markdown.js")

type
  AriaSnapshotRoot* {.pure.} = enum
    ## Source tree used for an ARIA snapshot.
    Readability, FullPage

  AriaActionKind* {.pure.} = enum
    ## Action supported by an ARIA ref.
    Click, Fill, Set, Select, Check, Uncheck

  AriaValueKind* {.pure.} = enum
    ## Value shape expected by an ARIA ref action.
    NoValue, Text, Number, Date, Time, DateTimeLocal, Month, Week, Range,
    Color, Select

  AriaSelectOption* = object
    ## Option metadata for a selectable ref.
    value*: string
    label*: string
    selected*: bool
    disabled*: bool

  AriaAction* = object
    ## Machine-readable action description for autocomplete or agent tools.
    kind*: AriaActionKind
    name*: string
    valueKind*: AriaValueKind
    options*: seq[AriaSelectOption]

  AriaSelectBy* = object
    ## Criteria for selecting one option in a ``<select>`` element.
    valueOrLabel*: Option[string]
    value*: Option[string]
    label*: Option[string]
    index*: Option[int]

  AriaOptions* = object
    ## Options passed to the bundled ARIA snapshot renderer.
    depth*: int
    boxes*: bool
    refPrefix*: string
    root*: AriaSnapshotRoot

  AriaActionRef* = object
    ## A ref from the latest ARIA snapshot classified by supported actions.
    refId*: string
    role*: string
    label*: string
    tag*: string
    value*: string
    valueKind*: AriaValueKind
    checked*: Option[bool]
    actions*: seq[AriaAction]
    selectOptions*: seq[AriaSelectOption]
    clickable*: bool
    fillable*: bool
    settable*: bool
    selectable*: bool
    checkable*: bool

  AriaLink* = object
    ## Link detected in the current page.
    refId*: string
      ## ARIA snapshot ref when the link is present in the current snapshot.
    text*: string
    href*: string
    role*: string

  KeySpec = object
    key: string
    code: string
    windowsVirtualKeyCode: int
    text: string
    modifiers: int

proc initAriaOptions*(depth = 0; boxes = false; refPrefix = "n";
                      root = AriaSnapshotRoot.Readability): AriaOptions =
  ## Build default ARIA snapshot options.
  result = AriaOptions(depth: depth, boxes: boxes, refPrefix: refPrefix,
                       root: root)

proc initAriaSelectBy*(valueOrLabel = ""; value = ""; label = "";
                       index = none(int)): AriaSelectBy =
  ## Build option-selection criteria for ``selectRef``.
  if valueOrLabel.len > 0: result.valueOrLabel = some(valueOrLabel)
  if value.len > 0: result.value = some(value)
  if label.len > 0: result.label = some(label)
  result.index = index

proc jsString(s: string): string = $(%s)

proc parseActionKind(s: string): AriaActionKind =
  case s
  of "click": AriaActionKind.Click
  of "fill": AriaActionKind.Fill
  of "set": AriaActionKind.Set
  of "select": AriaActionKind.Select
  of "check": AriaActionKind.Check
  of "uncheck": AriaActionKind.Uncheck
  else: AriaActionKind.Click

proc parseValueKind(s: string): AriaValueKind =
  case s
  of "text": AriaValueKind.Text
  of "number": AriaValueKind.Number
  of "date": AriaValueKind.Date
  of "time": AriaValueKind.Time
  of "datetime-local": AriaValueKind.DateTimeLocal
  of "month": AriaValueKind.Month
  of "week": AriaValueKind.Week
  of "range": AriaValueKind.Range
  of "color": AriaValueKind.Color
  of "select": AriaValueKind.Select
  else: AriaValueKind.NoValue

proc selectOptionFromJson(row: JsonNode): AriaSelectOption =
  result = AriaSelectOption(
    value: row.getOrDefault("value").getStr(""),
    label: row.getOrDefault("label").getStr(""),
    selected: row.getOrDefault("selected").getBool(false),
    disabled: row.getOrDefault("disabled").getBool(false))

proc selectOptionsFromJson(rows: JsonNode): seq[AriaSelectOption] =
  if rows.isNil or rows.kind != JArray: return
  for row in rows.items:
    if row.kind == JObject:
      result.add selectOptionFromJson(row)

proc actionFromJson(row: JsonNode): AriaAction =
  result = AriaAction(
    kind: parseActionKind(row.getOrDefault("kind").getStr("")),
    name: row.getOrDefault("name").getStr(""),
    valueKind: parseValueKind(row.getOrDefault("valueKind").getStr("")),
    options: selectOptionsFromJson(row.getOrDefault("options")))

proc actionsFromJson(rows: JsonNode): seq[AriaAction] =
  if rows.isNil or rows.kind != JArray: return
  for row in rows.items:
    if row.kind == JObject:
      result.add actionFromJson(row)

proc checkedFromJson(row: JsonNode): Option[bool] =
  let node = row.getOrDefault("checked")
  if not node.isNil and node.kind == JBool:
    result = some(node.getBool())

proc selectByJson(choice: AriaSelectBy): JsonNode =
  result = newJObject()
  if choice.valueOrLabel.isSome:
    result["valueOrLabel"] = %choice.valueOrLabel.get
  if choice.value.isSome:
    result["value"] = %choice.value.get
  if choice.label.isSome:
    result["label"] = %choice.label.get
  if choice.index.isSome:
    result["index"] = %choice.index.get

proc selectByJson(choices: openArray[AriaSelectBy]): JsonNode =
  result = newJArray()
  for choice in choices:
    result.add selectByJson(choice)

proc ariaSnapshotHelperSource(): string =
  ## Return the bundled Playwright helper without its ESM export footer.
  result = AriaHelperSource
  let exportAt = result.rfind("\nexport {")
  if exportAt >= 0:
    result.setLen(exportAt)

proc readabilitySource(): string =
  ## Return Mozilla Readability adapted for ncdp's in-page helper.
  ##
  ## The upstream CommonJS footer would mutate pages that define
  ## ``window.module``. The form/control cleanup replacements preserve controls
  ## in reduced views so agents can still inspect and act on forms.
  result = ReadabilitySource
  let exportAt = result.rfind("\nif (typeof module === \"object\")")
  if exportAt >= 0:
    result.setLen(exportAt)
  for replacement in [
    ("this._cleanConditionally(articleContent, \"form\");",
     "/* ncdp: preserve forms in reduced views */"),
    ("this._cleanConditionally(articleContent, \"fieldset\");",
     "/* ncdp: preserve fieldsets in reduced views */"),
    ("this._clean(articleContent, \"input\");",
     "/* ncdp: preserve inputs in reduced views */"),
    ("this._clean(articleContent, \"textarea\");",
     "/* ncdp: preserve textareas in reduced views */"),
    ("this._clean(articleContent, \"select\");",
     "/* ncdp: preserve selects in reduced views */"),
    ("this._clean(articleContent, \"button\");",
     "/* ncdp: preserve buttons in reduced views */"),
  ]:
    result = result.replace(replacement[0], replacement[1])

proc markdownSource(): string =
  ## Wrap the generated rehype/remark bundle so its top-level declarations cannot
  ## collide with the inspected page or with the ARIA helper closure.
  result = "(() => {\n" & MarkdownSource & "\n})();"

proc ariaRootName(root: AriaSnapshotRoot): string =
  case root
  of AriaSnapshotRoot.Readability: "readability"
  of AriaSnapshotRoot.FullPage: "fullPage"

proc ariaOptionsLiteral(opts: AriaOptions): string =
  let refPrefix = if opts.refPrefix.len == 0: "n" else: opts.refPrefix
  let node = %*{
    "mode": "ai",
    "refPrefix": refPrefix,
    "boxes": opts.boxes,
    "root": ariaRootName(opts.root),
  }
  if opts.depth > 0:
    node["depth"] = newJInt(opts.depth)
  result = $node

proc installAriaHelperExpression(): string =
  let helper = ariaSnapshotHelperSource()
  let readability = readabilitySource()
  let markdown = markdownSource()
  """
(() => {
  if (window.__ncdpAria?.version === 3 && window.__ncdpAria?.elementPoint &&
      window.__ncdpAria?.focusForFill)
    return "ok";
""" & readability & """
""" & markdown & """
""" & helper & """
  const root = () => document.body || document.documentElement;
  const originAttr = "data-ncdp-readability-origin";
  const textInputTypes = new Set([
    "", "text", "search", "url", "tel", "email", "password",
  ]);
  const setInputTypes = new Set([
    "number", "color", "date", "time", "datetime-local", "month",
    "range", "week",
  ]);
  const clickableRoles = new Set([
    "button", "link", "checkbox", "radio", "switch", "menuitem",
    "menuitemcheckbox", "menuitemradio", "option", "tab", "treeitem",
  ]);
  const defaultOptions = () => ({ mode: "ai", refPrefix: "n", root: "readability" });
  // Readability runs on a cloned document because it mutates aggressively. Tag
  // each clone node with its live-page origin so refs and Markdown form state can
  // later be mapped back to the browser DOM the user can actually interact with.
  const markCloneOrigins = (originalNode, clonedNode, originMap, nextId) => {
    if (originalNode?.nodeType === Node.ELEMENT_NODE &&
        clonedNode?.nodeType === Node.ELEMENT_NODE) {
      const id = String(nextId.value++);
      clonedNode.setAttribute(originAttr, id);
      originMap.set(id, originalNode);
    }
    let originalChild = originalNode?.firstChild;
    let clonedChild = clonedNode?.firstChild;
    while (originalChild && clonedChild) {
      markCloneOrigins(originalChild, clonedChild, originMap, nextId);
      originalChild = originalChild.nextSibling;
      clonedChild = clonedChild.nextSibling;
    }
  };
  const visibleForSnapshot = element =>
    !isElementHiddenForAria(element) || isElementVisible(element);
  const liveReceivesPointerEvents = element => {
    for (let e = element; e; e = parentElementOrShadowHost(e)) {
      const style = getElementComputedStyle(e);
      if (!style)
        return true;
      if (style.pointerEvents)
        return style.pointerEvents !== "none";
    }
    return true;
  };
  const pruneInvisibleCloneOrigins = (clonedDoc, originMap) => {
    // Detached clones do not have reliable computed style/layout. Prune by the
    // live origin element before Readability scores the clone, otherwise hidden
    // article content can leak into the reduced view.
    const nodes = [...clonedDoc.querySelectorAll(`[${originAttr}]`)];
    for (const node of nodes) {
      const original = originMap.get(node.getAttribute(originAttr));
      if (original && !visibleForSnapshot(original) && node.parentNode)
        node.remove();
    }
  };
  const hydrateImportedRefs = (rootElement, originMap) => {
    // Readability output is imported into a temporary live container. Reuse refs
    // already assigned to live elements so reduced snapshot refs remain stable
    // across observe/action/observe loops.
    for (const node of rootElement.querySelectorAll(`[${originAttr}]`)) {
      const original = originMap.get(node.getAttribute(originAttr));
      if (original?._ariaRef)
        node._ariaRef = original._ariaRef;
    }
  };
  const readabilityRoot = () => {
    if (typeof Readability !== "function")
      return null;
    const clonedDoc = document.cloneNode(true);
    const originMap = new Map();
    markCloneOrigins(document, clonedDoc, originMap, { value: 1 });
    pruneInvisibleCloneOrigins(clonedDoc, originMap);
    try {
      const article = new Readability(clonedDoc, { serializer: element => element }).parse();
      if (!article?.content)
        return null;
      const container = document.createElement("div");
      // The ARIA helper needs a live DOM subtree for computed style and layout.
      // Keep the temporary article out of normal stacking order and remove it in
      // the caller's finally block.
      container.style.position = "absolute";
      container.style.left = "0";
      container.style.top = "0";
      container.style.width = "100%";
      container.style.zIndex = "-2147483648";
      container.appendChild(document.importNode(article.content, true));
      hydrateImportedRefs(container, originMap);
      (document.body || document.documentElement).appendChild(container);
      return {
        root: container.firstElementChild || container,
        originMap,
        cleanup: () => container.remove(),
      };
    } catch (_) {
      return null;
    }
  };
  const snapshotSource = options => {
    if ((options || defaultOptions()).root === "fullPage")
      return { root: root(), originMap: null };
    return readabilityRoot() || { root: root(), originMap: null };
  };
  const remapNodeElements = (ariaNode, originMap) => {
    if (!ariaNode || typeof ariaNode === "string")
      return;
    const element = ariaNodeElement(ariaNode);
    const originId = element?.getAttribute?.(originAttr);
    const original = originId ? originMap.get(originId) : null;
    if (original) {
      setAriaNodeElement(ariaNode, original);
      // Ref actions use real CDP input against the live page. If the original is
      // hidden or pointer-blocked, drop the cloned ref instead of exposing a ref
      // that cannot be acted on safely.
      if (ariaNode.ref && (!computeBox(original).visible || !liveReceivesPointerEvents(original)))
        delete ariaNode.ref;
      if (ariaNode.ref)
        original._ariaRef = { role: ariaNode.role, name: ariaNode.name, ref: ariaNode.ref };
    }
    for (const child of ariaNode.children || [])
      remapNodeElements(child, originMap);
  };
  const remapSnapshotElements = (snapshot, originMap) => {
    if (!originMap)
      return;
    remapNodeElements(snapshot.root, originMap);
    const remapped = new Map();
    const refs = new Map();
    for (const [ref, element] of snapshot.elements || []) {
      const originId = element?.getAttribute?.(originAttr);
      const original = originId ? originMap.get(originId) : null;
      if (original?.isConnected && computeBox(original).visible &&
          liveReceivesPointerEvents(original)) {
        remapped.set(ref, original);
        refs.set(original, ref);
      }
    }
    snapshot.elements = remapped;
    snapshot.refs = refs;
  };
  const originalScopeElements = (rootElement, originMap) => {
    // links() should report visible links from the reduced article even when a
    // specific link is not interactable enough to receive an ARIA ref.
    const result = new Set();
    if (!originMap)
      return result;
    const addOriginal = node => {
      const originId = node?.getAttribute?.(originAttr);
      const original = originId ? originMap.get(originId) : null;
      if (original?.isConnected)
        result.add(original);
    };
    addOriginal(rootElement);
    for (const node of rootElement.querySelectorAll?.(`[${originAttr}]`) || [])
      addOriginal(node);
    return result;
  };
  const syncControlState = (target, source) => {
    // HTML serialization reads attributes/text, while browser form state lives
    // on properties. Copy current live properties onto a markdown-only clone so
    // fill/select/set actions are reflected in the next Markdown observation.
    if (!target || !source)
      return;
    if (target instanceof HTMLInputElement && source instanceof HTMLInputElement) {
      target.setAttribute("value", source.value || "");
      if (["checkbox", "radio"].includes(source.type)) {
        if (source.checked) target.setAttribute("checked", "");
        else target.removeAttribute("checked");
      }
    } else if (target instanceof HTMLTextAreaElement && source instanceof HTMLTextAreaElement) {
      target.textContent = source.value || "";
    } else if (target instanceof HTMLSelectElement && source instanceof HTMLSelectElement) {
      const targetOptions = [...target.options];
      const sourceOptions = [...source.options];
      for (let i = 0; i < targetOptions.length && i < sourceOptions.length; i++) {
        if (sourceOptions[i].selected) targetOptions[i].setAttribute("selected", "");
        else targetOptions[i].removeAttribute("selected");
      }
    } else if (target instanceof HTMLButtonElement && source instanceof HTMLButtonElement) {
      target.setAttribute("value", source.value || "");
    }
  };
  const controlElements = rootElement => {
    const result = [];
    if (rootElement.matches?.("input,textarea,select,button"))
      result.push(rootElement);
    result.push(...rootElement.querySelectorAll?.("input,textarea,select,button") || []);
    return result;
  };
  const refAnnotatableElements = rootElement => {
    const selector = "a[href],input,textarea,select,button";
    const result = [];
    if (rootElement.matches?.(selector))
      result.push(rootElement);
    result.push(...rootElement.querySelectorAll?.(selector) || []);
    return result;
  };
  const annotateMarkdownRefs = (clone, source) => {
    const clonedElements = refAnnotatableElements(clone);
    if (source.originMap) {
      for (const element of clonedElements) {
        const originId = element.getAttribute?.(originAttr);
        const ref = originId ? source.originMap.get(originId)?._ariaRef?.ref : "";
        if (ref) element.setAttribute("data-ncdp-ref", ref);
      }
      return;
    }
    const sourceElements = refAnnotatableElements(source.root);
    for (let i = 0; i < clonedElements.length && i < sourceElements.length; i++) {
      const ref = sourceElements[i]?._ariaRef?.ref;
      if (ref) clonedElements[i].setAttribute("data-ncdp-ref", ref);
    }
  };
  const markdownHtml = source => {
    // Never serialize the temporary/live subtree directly: clone first, then
    // normalize control state on the clone for the rehype/remark converter.
    const clone = source.root.cloneNode(true);
    annotateMarkdownRefs(clone, source);
    if (source.originMap) {
      for (const control of controlElements(clone)) {
        const originId = control.getAttribute?.(originAttr);
        syncControlState(control, originId ? source.originMap.get(originId) : null);
      }
    } else {
      const clonedControls = controlElements(clone);
      const sourceControls = controlElements(source.root);
      for (let i = 0; i < clonedControls.length && i < sourceControls.length; i++)
        syncControlState(clonedControls[i], sourceControls[i]);
    }
    return clone.innerHTML || clone.textContent || "";
  };
  const refresh = options => {
    window.__ncdpAriaLastOptions = options || defaultOptions();
    const source = snapshotSource(window.__ncdpAriaLastOptions);
    const scope = originalScopeElements(source.root, source.originMap);
    try {
      const snapshot = generateAriaTree(source.root, window.__ncdpAriaLastOptions);
      remapSnapshotElements(snapshot, source.originMap);
      window.__ncdpAriaElements = snapshot.elements;
      window.__ncdpAriaRefs = snapshot.refs;
      window.__ncdpAriaScope = scope;
      window.__ncdpAriaReduced = !!source.originMap;
      return snapshot;
    } finally {
      source.cleanup?.();
    }
  };
  const elementForRef = ref => {
    const current = window.__ncdpAriaElements?.get(ref);
    if (current && current.isConnected)
      return current;
    refresh(window.__ncdpAriaLastOptions || defaultOptions());
    return window.__ncdpAriaElements?.get(ref);
  };
  const normalizedText = value => String(value || "").trim().replace(/\s+/g, " ");
  const roleFor = element => {
    const role = element.getAttribute("role");
    if (role)
      return role;
    if (element instanceof HTMLAnchorElement && element.href)
      return "link";
    if (element instanceof HTMLButtonElement)
      return "button";
    if (element instanceof HTMLTextAreaElement)
      return "textbox";
    if (element instanceof HTMLSelectElement)
      return element.multiple || element.size > 1 ? "listbox" : "combobox";
    if (element instanceof HTMLInputElement) {
      if (element.type === "checkbox") return "checkbox";
      if (element.type === "radio") return "radio";
      if (element.type === "number") return "spinbutton";
      if (element.type === "range") return "slider";
      if (textInputTypes.has(element.type)) return "textbox";
      if (setInputTypes.has(element.type)) return "textbox";
      if (element.type === "button" || element.type === "submit" || element.type === "reset")
        return "button";
    }
    return element.localName;
  };
  const associatedLabelText = element => {
    if (!element.labels?.length) return "";
    return [...element.labels].map(label => {
      const clone = label.cloneNode(true);
      for (const control of clone.querySelectorAll("button,input,select,textarea"))
        control.remove();
      return normalizedText(clone.textContent || "");
    }).filter(Boolean).join(" ");
  };
  const labelFor = element => normalizedText(
    element.getAttribute("aria-label") ||
    element.getAttribute("alt") ||
    associatedLabelText(element) ||
    element.innerText ||
    element.value ||
    element.getAttribute("placeholder") ||
    element.getAttribute("title") ||
    "");
  const isTextInput = element =>
    element instanceof HTMLTextAreaElement ||
    element.isContentEditable ||
    (element instanceof HTMLInputElement && textInputTypes.has(element.type));
  const isSettableInput = element =>
    element instanceof HTMLInputElement && setInputTypes.has(element.type);
  const valueKindFor = element => {
    if (isTextInput(element)) return "text";
    if (element instanceof HTMLSelectElement) return "select";
    if (element instanceof HTMLInputElement && setInputTypes.has(element.type))
      return element.type;
    return "none";
  };
  const currentValue = element => {
    if (element instanceof HTMLInputElement || element instanceof HTMLTextAreaElement ||
        element instanceof HTMLSelectElement)
      return element.value || "";
    if (element.isContentEditable)
      return element.innerText || "";
    return "";
  };
  const isCheckable = element => {
    const role = roleFor(element);
    return role === "checkbox" || role === "radio" || role === "switch" ||
      (element instanceof HTMLInputElement && ["checkbox", "radio"].includes(element.type));
  };
  const checkedFor = element => {
    if (element instanceof HTMLInputElement && ["checkbox", "radio"].includes(element.type))
      return element.checked;
    const role = roleFor(element);
    if (["checkbox", "radio", "switch", "menuitemcheckbox", "menuitemradio"].includes(role)) {
      const checked = element.getAttribute("aria-checked");
      if (checked === "true") return true;
      if (checked === "false") return false;
    }
    return null;
  };
  const selectOptionsFor = element => {
    if (!(element instanceof HTMLSelectElement)) return [];
    return [...element.options].map(option => ({
      value: option.value,
      label: normalizedText(option.label || option.textContent || option.value),
      selected: option.selected,
      disabled: option.disabled || !!option.closest("optgroup[disabled]"),
    }));
  };
  const action = (kind, valueKind = "none", options = []) => ({
    kind,
    name: kind,
    valueKind,
    options,
  });
  const actionsFor = element => {
    const actions = [];
    const valueKind = valueKindFor(element);
    if (isClickable(element)) actions.push(action("click"));
    if (isTextInput(element)) actions.push(action("fill", "text"));
    if (isSettableInput(element)) actions.push(action("set", valueKind));
    if (element instanceof HTMLSelectElement)
      actions.push(action("select", "select", selectOptionsFor(element)));
    if (isCheckable(element)) {
      const checked = checkedFor(element);
      if (checked !== true) actions.push(action("check"));
      if (checked === true || roleFor(element) !== "radio")
        actions.push(action("uncheck"));
    }
    return actions;
  };
  const isClickable = element => {
    if (element.disabled || element.getAttribute("aria-disabled") === "true")
      return false;
    const role = roleFor(element);
    return clickableRoles.has(role) ||
      element instanceof HTMLAnchorElement && !!element.href ||
      element instanceof HTMLButtonElement ||
      element instanceof HTMLSelectElement ||
      element instanceof HTMLTextAreaElement ||
      element instanceof HTMLInputElement && element.type !== "hidden" ||
      element.hasAttribute("onclick");
  };
  const dispatchInputAndChange = element => {
    element.dispatchEvent(new Event("input", { bubbles: true, composed: true }));
    element.dispatchEvent(new Event("change", { bubbles: true }));
  };
  const setValue = (element, value) => {
    if (!(element instanceof HTMLInputElement) || !setInputTypes.has(element.type))
      throw new Error("ref is not settable");
    value = String(value).trim();
    if (element.type === "color")
      value = value.toLowerCase();
    element.focus();
    element.value = value;
    if (element.value !== value)
      throw new Error("Malformed value");
    dispatchInputAndChange(element);
    return element.value;
  };
  const optionMatches = (option, matcher, index) => {
    const label = option.label || "";
    const normalizedLabel = normalizedText(label);
    const matchesLabel = value => value === label || normalizedText(value) === normalizedLabel;
    let matches = true;
    if (matcher.valueOrLabel !== undefined)
      matches = matches && (matcher.valueOrLabel === option.value || matchesLabel(matcher.valueOrLabel));
    if (matcher.value !== undefined)
      matches = matches && matcher.value === option.value;
    if (matcher.label !== undefined)
      matches = matches && matchesLabel(matcher.label);
    if (matcher.index !== undefined)
      matches = matches && matcher.index === index;
    return matches;
  };
  const selectOptions = (element, matchers) => {
    if (!(element instanceof HTMLSelectElement))
      throw new Error("Element is not a <select> element");
    const options = [...element.options];
    const selectedOptions = [];
    let remaining = matchers.slice();
    for (let index = 0; index < options.length; index++) {
      const option = options[index];
      const matcher = remaining.find(item => optionMatches(option, item, index));
      if (!matcher) continue;
      if (option.disabled || option.closest("optgroup[disabled]"))
        throw new Error("Option being selected is not enabled");
      selectedOptions.push(option);
      if (element.multiple)
        remaining = remaining.filter(item => !optionMatches(option, item, index));
      else {
        remaining = [];
        break;
      }
    }
    if (remaining.length)
      throw new Error("Did not find some options");
    element.value = undefined;
    for (const option of options)
      option.selected = false;
    for (const option of selectedOptions)
      option.selected = true;
    dispatchInputAndChange(element);
    return selectedOptions.map(option => option.value);
  };
  const reverseRefs = () => {
    const refs = new Map();
    for (const [ref, element] of window.__ncdpAriaElements || [])
      refs.set(element, ref);
    return refs;
  };
  const waitForScroll = () => new Promise(resolve => {
    const raf = window.requestAnimationFrame || (fn => setTimeout(fn, 0));
    raf(() => raf(resolve));
  });
  const elementSummary = element => {
    if (!element)
      return "none";
    let result = element.localName || String(element.tagName || "element").toLowerCase();
    if (element.id)
      result += `#${element.id}`;
    const className = typeof element.className === "string"
      ? element.className
      : element.getAttribute?.("class") || "";
    const classes = normalizedText(className).replace(/\s+/g, ".");
    if (classes)
      result += `.${classes}`;
    const text = normalizedText(element.innerText || element.textContent || "").slice(0, 80);
    if (text)
      result += ` "${text}"`;
    return result;
  };
  const hitReaches = (element, hit) => !!hit && (hit === element || element.contains(hit));
  const inViewport = (x, y) => x >= 0 && y >= 0 && x < innerWidth && y < innerHeight;
  const candidatePoints = rect => {
    const padX = Math.min(8, rect.width / 2);
    const padY = Math.min(8, rect.height / 2);
    return [
      [rect.left + rect.width / 2, rect.top + rect.height / 2],
      [rect.left + padX, rect.top + padY],
      [rect.right - padX, rect.top + padY],
      [rect.left + padX, rect.bottom - padY],
      [rect.right - padX, rect.bottom - padY],
    ];
  };
  const reachablePoint = element => {
    let sample = null;
    const rects = [...element.getClientRects()].filter(rect => rect.width > 0 && rect.height > 0);
    for (const rect of rects) {
      for (const [x, y] of candidatePoints(rect)) {
        if (!inViewport(x, y))
          continue;
        const hit = document.elementFromPoint(x, y);
        if (!sample)
          sample = { x, y, hit };
        if (hitReaches(element, hit))
          return { x, y };
      }
    }
    return { sample };
  };
  window.__ncdpAria = {
    version: 3,
    snapshotText(options) {
      return renderAriaTree(refresh(options), window.__ncdpAriaLastOptions).text;
    },
    markdown(options) {
      const resolvedOptions = options || window.__ncdpAriaLastOptions || defaultOptions();
      refresh(resolvedOptions);
      const source = snapshotSource(resolvedOptions);
      try {
        return globalThis.__ncdpHtmlToMarkdown(markdownHtml(source));
      } finally {
        source.cleanup?.();
      }
    },
    actionRefs(options) {
      refresh(options || window.__ncdpAriaLastOptions || defaultOptions());
      const rows = [];
      for (const [ref, element] of window.__ncdpAriaElements || []) {
        if (!element?.isConnected)
          continue;
        const actions = actionsFor(element);
        const row = {
          refId: ref,
          role: roleFor(element),
          label: labelFor(element).slice(0, 100),
          tag: element.localName,
          value: currentValue(element),
          valueKind: valueKindFor(element),
          checked: checkedFor(element),
          actions,
          selectOptions: selectOptionsFor(element),
          clickable: actions.some(action => action.kind === "click"),
          fillable: actions.some(action => action.kind === "fill"),
          settable: actions.some(action => action.kind === "set"),
          selectable: actions.some(action => action.kind === "select"),
          checkable: isCheckable(element),
        };
        if (row.actions.length)
          rows.push(row);
      }
      return rows;
    },
    links(options) {
      refresh(options || window.__ncdpAriaLastOptions || defaultOptions());
      const refs = window.__ncdpAriaRefs || reverseRefs();
      const scope = window.__ncdpAriaReduced ? window.__ncdpAriaScope || new Set() : new Set();
      const seen = new Set();
      const rows = [];
      for (const element of document.querySelectorAll('a[href], [role="link"]')) {
        if (!element.isConnected || seen.has(element))
          continue;
        if (scope.size && !scope.has(element) && ![...scope].some(item => item.contains(element)))
          continue;
        seen.add(element);
        rows.push({
          refId: refs.get(element) || "",
          text: labelFor(element).slice(0, 100),
          href: element.href || element.getAttribute("href") || "",
          role: roleFor(element),
        });
      }
      return rows;
    },
    async elementPoint(ref) {
      const element = elementForRef(ref);
      if (!element)
        throw new Error(`No element for ref=${ref}. Run snapshot and use a visible ref.`);
      element.scrollIntoView({ block: "center", inline: "center", behavior: "instant" });
      await waitForScroll();
      const point = reachablePoint(element);
      if (point.x !== undefined)
        return point;
      const rect = element.getBoundingClientRect();
      if (!rect.width || !rect.height)
        throw new Error(`ref=${ref} has no clickable box`);
      const sample = point.sample || {
        x: rect.left + rect.width / 2,
        y: rect.top + rect.height / 2,
        hit: document.elementFromPoint(rect.left + rect.width / 2, rect.top + rect.height / 2),
      };
      throw new Error(
        `ref=${ref} click intercepted; top element at ` +
        `(${sample.x.toFixed(1)}, ${sample.y.toFixed(1)}) is ` +
        `${elementSummary(sample.hit)}; target is ${elementSummary(element)}`);
    },
    focusForFill(ref) {
      const element = elementForRef(ref);
      if (!element)
        throw new Error(`No element for ref=${ref}. Run snapshot and use a visible ref.`);
      element.scrollIntoView({ block: "center", inline: "center" });
      if (element instanceof HTMLInputElement) {
        if (!textInputTypes.has(element.type))
          throw new Error(`ref=${ref} is not fillable`);
        element.focus();
        element.select();
      } else if (element instanceof HTMLTextAreaElement) {
        element.focus();
        element.select();
      } else if (element.isContentEditable) {
        element.focus();
        const range = document.createRange();
        range.selectNodeContents(element);
        const selection = getSelection();
        selection.removeAllRanges();
        selection.addRange(range);
      } else {
        throw new Error(`ref=${ref} is not fillable`);
      }
      return "ok";
    },
    setValue(ref, value) {
      const element = elementForRef(ref);
      if (!element)
        throw new Error(`No element for ref=${ref}. Run snapshot and use a visible ref.`);
      element.scrollIntoView({ block: "center", inline: "center" });
      return setValue(element, value);
    },
    selectValue(ref, matchers) {
      const element = elementForRef(ref);
      if (!element)
        throw new Error(`No element for ref=${ref}. Run snapshot and use a visible ref.`);
      element.scrollIntoView({ block: "center", inline: "center" });
      return selectOptions(element, matchers);
    },
  };
  return "ok";
})()
"""

proc ensureAriaHelper*(p: Page): Future[void] {.
    async: (raises: [CatchableError]).} =
  ## Install the bundled ARIA helper into the inspected page if needed.
  discard await p.evalString(installAriaHelperExpression())

proc modifierBit(name: string): int =
  case name.toLowerAscii()
  of "alt", "option": 1
  of "ctrl", "control": 2
  of "meta", "cmd", "command", "super": 4
  of "shift": 8
  else: 0

proc specialKey(name: string; spec: var KeySpec): bool =
  let lower = name.toLowerAscii()
  case lower
  of "enter", "return":
    spec.key = "Enter"; spec.code = "Enter"; spec.windowsVirtualKeyCode = 13
  of "tab":
    spec.key = "Tab"; spec.code = "Tab"; spec.windowsVirtualKeyCode = 9
  of "escape", "esc":
    spec.key = "Escape"; spec.code = "Escape"; spec.windowsVirtualKeyCode = 27
  of "backspace":
    spec.key = "Backspace"; spec.code = "Backspace"; spec.windowsVirtualKeyCode = 8
  of "delete", "del":
    spec.key = "Delete"; spec.code = "Delete"; spec.windowsVirtualKeyCode = 46
  of "arrowleft", "left":
    spec.key = "ArrowLeft"; spec.code = "ArrowLeft"; spec.windowsVirtualKeyCode = 37
  of "arrowup", "up":
    spec.key = "ArrowUp"; spec.code = "ArrowUp"; spec.windowsVirtualKeyCode = 38
  of "arrowright", "right":
    spec.key = "ArrowRight"; spec.code = "ArrowRight"; spec.windowsVirtualKeyCode = 39
  of "arrowdown", "down":
    spec.key = "ArrowDown"; spec.code = "ArrowDown"; spec.windowsVirtualKeyCode = 40
  of "home":
    spec.key = "Home"; spec.code = "Home"; spec.windowsVirtualKeyCode = 36
  of "end":
    spec.key = "End"; spec.code = "End"; spec.windowsVirtualKeyCode = 35
  of "pageup":
    spec.key = "PageUp"; spec.code = "PageUp"; spec.windowsVirtualKeyCode = 33
  of "pagedown":
    spec.key = "PageDown"; spec.code = "PageDown"; spec.windowsVirtualKeyCode = 34
  of "space":
    spec.key = " "; spec.code = "Space"; spec.windowsVirtualKeyCode = 32
    spec.text = " "
  else:
    if lower.len >= 2 and lower[0] == 'f':
      try:
        let n = parseInt(lower[1 .. ^1])
        if n >= 1 and n <= 12:
          spec.key = "F" & $n
          spec.code = spec.key
          spec.windowsVirtualKeyCode = 111 + n
          return true
      except ValueError:
        discard
    return false
  result = true

proc parseKeySpec(input: string): KeySpec =
  let parts = input.split('+').mapIt(it.strip()).filterIt(it.len > 0)
  if parts.len == 0:
    raise newException(NcdpError, "empty key")
  for part in parts[0 ..< parts.high]:
    let bit = modifierBit(part)
    if bit == 0:
      raise newException(NcdpError, "unknown modifier: " & part)
    result.modifiers = result.modifiers or bit
  let keyPart = parts[^1]
  if specialKey(keyPart, result):
    return
  if keyPart.len == 1:
    let ch = keyPart[0]
    result.key = $ch
    if ch in {'a'..'z', 'A'..'Z'}:
      let upper = ($ch).toUpperAscii()
      result.code = "Key" & upper
      result.windowsVirtualKeyCode = ord(upper[0])
      if (result.modifiers and 8) != 0:
        result.key = upper
        result.text = upper
      else:
        result.text = $ch
    elif ch in {'0'..'9'}:
      result.code = "Digit" & $ch
      result.windowsVirtualKeyCode = ord(ch)
      result.text = $ch
    else:
      result.code = ""
      result.windowsVirtualKeyCode = ord(ch)
      result.text = $ch
    if (result.modifiers and (1 or 2 or 4)) != 0:
      result.text = ""
    return
  raise newException(NcdpError, "unsupported key: " & input)

proc dispatchKey(p: Page; spec: KeySpec) {.async: (raises: [CatchableError]).} =
  let hasText = spec.text.len > 0
  await cdpInput.dispatchKeyEvent(p.client,
    `type` = if hasText: InputDispatchKeyEventParamsType.KeyDown
             else: InputDispatchKeyEventParamsType.RawKeyDown,
    modifiers = if spec.modifiers == 0: none(int) else: some(spec.modifiers),
    timestamp = none(InputTimeSinceEpoch),
    text = if hasText: some(spec.text) else: none(string),
    unmodifiedText = if hasText: some(spec.text) else: none(string),
    keyIdentifier = none(string),
    code = if spec.code.len > 0: some(spec.code) else: none(string),
    key = some(spec.key),
    windowsVirtualKeyCode = some(spec.windowsVirtualKeyCode),
    nativeVirtualKeyCode = some(spec.windowsVirtualKeyCode),
    autoRepeat = none(bool),
    isKeypad = none(bool),
    isSystemKey = none(bool),
    location = none(int),
    commands = none(seq[string]))
  await cdpInput.dispatchKeyEvent(p.client,
    `type` = InputDispatchKeyEventParamsType.KeyUp,
    modifiers = if spec.modifiers == 0: none(int) else: some(spec.modifiers),
    timestamp = none(InputTimeSinceEpoch),
    text = none(string),
    unmodifiedText = none(string),
    keyIdentifier = none(string),
    code = if spec.code.len > 0: some(spec.code) else: none(string),
    key = some(spec.key),
    windowsVirtualKeyCode = some(spec.windowsVirtualKeyCode),
    nativeVirtualKeyCode = some(spec.windowsVirtualKeyCode),
    autoRepeat = none(bool),
    isKeypad = none(bool),
    isSystemKey = none(bool),
    location = none(int),
    commands = none(seq[string]))

proc refPoint(p: Page; refId: string): Future[tuple[x, y: float]] {.
    async: (raises: [CatchableError]).} =
  await p.ensureAriaHelper()
  let point = await p.evalJson("(() => window.__ncdpAria.elementPoint(" &
                               jsString(refId) & "))()")
  if point.kind != JObject:
    raise newException(NcdpError, "ARIA ref did not return a point")
  let xNode = point.getOrDefault("x")
  let yNode = point.getOrDefault("y")
  if xNode.isNil or yNode.isNil:
    raise newException(NcdpError, "ARIA ref point missing coordinates")
  result = (x: xNode.getFloat(), y: yNode.getFloat())

proc ariaSnapshot*(p: Page; opts: AriaOptions): Future[string] {.
    async: (raises: [CatchableError]).} =
  ## Return a Playwright-style, AI-friendly ARIA tree snapshot.
  await p.ensureAriaHelper()
  result = await p.evalString("(() => window.__ncdpAria.snapshotText(" &
                              ariaOptionsLiteral(opts) & "))()")

proc ariaSnapshot*(p: Page; depth = 0; boxes = false): Future[string] {.
    async: (raises: [CatchableError]).} =
  ## Return an ARIA snapshot using the default ``n`` ref prefix.
  result = await p.ariaSnapshot(initAriaOptions(depth = depth, boxes = boxes))

proc readableMarkdown*(p: Page; opts = initAriaOptions()): Future[string] {.
    async: (raises: [CatchableError]).} =
  ## Return Markdown converted from the current Readability-reduced HTML view.
  ##
  ## Pass ``initAriaOptions(root = AriaSnapshotRoot.FullPage)`` to convert the
  ## full page body instead of the default reduced article view.
  await p.ensureAriaHelper()
  result = await p.evalString("(() => window.__ncdpAria.markdown(" &
                              ariaOptionsLiteral(opts) & "))()")

proc actionRefs*(p: Page; opts = initAriaOptions()): Future[seq[AriaActionRef]] {.
    async: (raises: [CatchableError]).} =
  ## Return actionable refs from the current page's ARIA snapshot.
  await p.ensureAriaHelper()
  let rows = await p.evalJson("(() => window.__ncdpAria.actionRefs(" &
                              ariaOptionsLiteral(opts) & "))()")
  if rows.kind != JArray:
    raise newException(NcdpError, "ARIA action refs did not return an array")
  for row in rows.items:
    if row.kind != JObject: continue
    result.add AriaActionRef(
      refId: row.getOrDefault("refId").getStr(""),
      role: row.getOrDefault("role").getStr(""),
      label: row.getOrDefault("label").getStr(""),
      tag: row.getOrDefault("tag").getStr(""),
      value: row.getOrDefault("value").getStr(""),
      valueKind: parseValueKind(row.getOrDefault("valueKind").getStr("")),
      checked: checkedFromJson(row),
      actions: actionsFromJson(row.getOrDefault("actions")),
      selectOptions: selectOptionsFromJson(row.getOrDefault("selectOptions")),
      clickable: row.getOrDefault("clickable").getBool(false),
      fillable: row.getOrDefault("fillable").getBool(false),
      settable: row.getOrDefault("settable").getBool(false),
      selectable: row.getOrDefault("selectable").getBool(false),
      checkable: row.getOrDefault("checkable").getBool(false))

proc links*(p: Page; opts = initAriaOptions()): Future[seq[AriaLink]] {.
    async: (raises: [CatchableError]).} =
  ## Return all links in the current page, including ARIA refs when present in
  ## the latest snapshot.
  await p.ensureAriaHelper()
  let rows = await p.evalJson("(() => window.__ncdpAria.links(" &
                              ariaOptionsLiteral(opts) & "))()")
  if rows.kind != JArray:
    raise newException(NcdpError, "ARIA links did not return an array")
  for row in rows.items:
    if row.kind != JObject: continue
    result.add AriaLink(
      refId: row.getOrDefault("refId").getStr(""),
      text: row.getOrDefault("text").getStr(""),
      href: row.getOrDefault("href").getStr(""),
      role: row.getOrDefault("role").getStr(""))

proc clickRef*(p: Page; refId: string): Future[string] {.
    async: (raises: [CatchableError]).} =
  ## Click an element from the most recent ARIA snapshot by ref id using real
  ## CDP mouse input at the element's center point.
  let point = await p.refPoint(refId)
  await cdpInput.dispatchMouseEvent(p.client,
    `type` = InputDispatchMouseEventParamsType.MouseMoved,
    x = point.x, y = point.y,
    modifiers = none(int), timestamp = none(InputTimeSinceEpoch),
    button = none(InputMouseButton), buttons = none(int), clickCount = none(int),
    force = none(float), tangentialPressure = none(float),
    tiltX = none(float), tiltY = none(float), twist = none(int),
    deltaX = none(float), deltaY = none(float),
    pointerType = some(InputDispatchMouseEventParamsPointerType.Mouse))
  await cdpInput.dispatchMouseEvent(p.client,
    `type` = InputDispatchMouseEventParamsType.MousePressed,
    x = point.x, y = point.y,
    modifiers = none(int), timestamp = none(InputTimeSinceEpoch),
    button = some(InputMouseButton.Left), buttons = some(1), clickCount = some(1),
    force = none(float), tangentialPressure = none(float),
    tiltX = none(float), tiltY = none(float), twist = none(int),
    deltaX = none(float), deltaY = none(float),
    pointerType = some(InputDispatchMouseEventParamsPointerType.Mouse))
  await cdpInput.dispatchMouseEvent(p.client,
    `type` = InputDispatchMouseEventParamsType.MouseReleased,
    x = point.x, y = point.y,
    modifiers = none(int), timestamp = none(InputTimeSinceEpoch),
    button = some(InputMouseButton.Left), buttons = some(0), clickCount = some(1),
    force = none(float), tangentialPressure = none(float),
    tiltX = none(float), tiltY = none(float), twist = none(int),
    deltaX = none(float), deltaY = none(float),
    pointerType = some(InputDispatchMouseEventParamsPointerType.Mouse))
  result = "clicked " & refId

proc fillRef*(p: Page; refId, text: string): Future[string] {.
    async: (raises: [CatchableError]).} =
  ## Fill an input/contenteditable element using focus/selection plus CDP text
  ## insertion, not direct DOM value mutation.
  await p.ensureAriaHelper()
  discard await p.evalString("(() => window.__ncdpAria.focusForFill(" &
                             jsString(refId) & "))()")
  await cdpInput.insertText(p.client, text)
  result = "filled " & refId

proc setRef*(p: Page; refId, value: string): Future[string] {.
    async: (raises: [CatchableError]).} =
  ## Set a non-text input value such as ``number``, ``date``, ``time``,
  ## ``datetime-local``, ``month``, ``week``, ``range``, or ``color``.
  ##
  ## The browser validates the assigned value; malformed native-control values
  ## raise ``NcdpError`` via ``Runtime.evaluate``.
  await p.ensureAriaHelper()
  let actual = await p.evalString("(() => window.__ncdpAria.setValue(" &
                                  jsString(refId) & ", " & jsString(value) &
                                  "))()")
  result = "set " & refId & " = " & actual

proc selectRef*(p: Page; refId: string;
                choices: seq[AriaSelectBy]): Future[seq[string]] {.
    async: (raises: [CatchableError]).} =
  ## Select options in a ``<select>`` ref and return selected option values.
  ##
  ## Empty ``choices`` clears the selection. Single-select elements choose the
  ## first matched option; multi-select elements select every matched option.
  await p.ensureAriaHelper()
  let selected = await p.evalJson("(() => window.__ncdpAria.selectValue(" &
                                  jsString(refId) & ", " &
                                  $selectByJson(choices) & "))()")
  if selected.kind != JArray:
    raise newException(NcdpError, "selectRef did not return an array")
  for item in selected.items:
    if item.kind == JString:
      result.add item.getStr()

proc selectRef*(p: Page; refId, valueOrLabel: string): Future[seq[string]] {.
    async: (raises: [CatchableError]).} =
  ## Select one option by value or label text.
  let choice = initAriaSelectBy(valueOrLabel = valueOrLabel)
  result = await p.selectRef(refId, @[choice])

proc press*(p: Page; key: string): Future[string] {.
    async: (raises: [CatchableError]).} =
  ## Press a key using CDP ``Input.dispatchKeyEvent``.
  ##
  ## Supports special keys such as ``Tab``, ``Enter``/``Return``, ``Escape``,
  ## arrows, ``Home``, ``End``, ``PageUp``, ``PageDown``, ``Backspace``,
  ## ``Delete``, ``F1``-``F12``, and modifier chords such as ``Shift+Tab`` or
  ## ``Ctrl+L``.
  let spec = parseKeySpec(key)
  await p.dispatchKey(spec)
  result = "pressed " & key
