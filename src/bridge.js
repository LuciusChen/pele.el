/* SPDX-License-Identifier: MIT */
/* Host adapter; vendor/pele/pele.global.js is kept unmodified. */
"use strict";

(() => {
  const textWidths = new Map();
  const decode = value => value.replace(/&(?:quot|apos|lt|gt|amp);/g,
    entity => ({"&quot;": '"', "&apos;": "'", "&lt;": "<", "&gt;": ">", "&amp;": "&"})[entity]);
  const escape = value => String(value).replace(/[&"<>]/g,
    character => ({"&": "&amp;", '"': "&quot;", "<": "&lt;", ">": "&gt;"})[character]);

  // Pele emits presentation attributes and inline CSS, not stylesheet rules.
  // Resolve scoped custom properties before handing SVG to a non-browser viewer.
  function resolve(value, variables, seen = new Set()) {
    let output = "";
    let offset = 0;
    while (offset < value.length) {
      const start = value.indexOf("var(", offset);
      if (start < 0) return output + value.slice(offset);
      output += value.slice(offset, start);
      let depth = 1, end = start + 4, comma = -1;
      for (; end < value.length && depth; end++) {
        if (value[end] === "(") depth++;
        else if (value[end] === ")") depth--;
        else if (value[end] === "," && depth === 1 && comma < 0) comma = end;
      }
      if (depth) throw new Error("Unclosed CSS variable in generated SVG");
      const key = value.slice(start + 4, comma < 0 ? end - 1 : comma).trim();
      const fallback = comma < 0 ? "" : value.slice(comma + 1, end - 1).trim();
      const next = new Set(seen);
      const replacement = !seen.has(key) && Object.hasOwn(variables, key)
        ? (next.add(key), variables[key]) : fallback;
      output += resolve(replacement, variables, next);
      offset = end;
    }
    return output;
  }

  function portableSvg(svg, theme, transparent) {
    const stack = [Object.assign(Object.create(null), theme)];
    return svg.replace(/<\/?[\w:-]+(?:\s[^<>]*?)?\s*\/?>/g, tag => {
      if (tag.startsWith("</")) {
        stack.pop();
        return tag;
      }
      const name = /^<([\w:-]+)/.exec(tag)[1];
      const attributes = [];
      for (const match of tag.matchAll(/([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')/g)) {
        attributes.push([match[1], decode(match[2] ?? match[3])]);
      }
      const parent = stack[stack.length - 1];
      const variables = Object.assign(Object.create(null), parent);
      const style = attributes.find(([key]) => key === "style")?.[1] ?? "";
      const declarations = style.split(";").flatMap(declaration => {
        const colon = declaration.indexOf(":");
        return colon < 0 ? [] : [[declaration.slice(0, colon).trim(), declaration.slice(colon + 1).trim()]];
      });
      for (const [key, value] of declarations) {
        if (key.startsWith("--")) variables[key] = value;
      }
      // Inherited custom properties are already computed in their defining scope.
      const computed = Object.assign(Object.create(null), variables);
      for (const [key] of declarations) {
        if (key.startsWith("--")) computed[key] = resolve(variables[key], variables);
      }
      const plainStyle = declarations.filter(([key]) => !key.startsWith("--"))
        .map(([key, value]) => [key, resolve(value, computed)]);
      const radius = plainStyle.find(([key]) => key === "rx");
      if (radius && !attributes.some(([key]) => key === "rx")) attributes.push(["rx", radius[1]]);
      const output = attributes.flatMap(([key, value]) => {
        if (key === "style") {
          const css = plainStyle.filter(([property]) => property !== "rx")
            .map(([property, text]) => `${property}:${text}`).join(";");
          return css ? [[key, css]] : [];
        }
        return [[key, resolve(value, computed)]];
      });
      const root = name === "svg" && stack.length === 1;
      if (!tag.endsWith("/>")) stack.push(computed);
      const background = root && !transparent
        ? `<rect class="pele-background" width="100%" height="100%" fill="${escape(resolve("var(--_bg)", computed))}"/>` : "";
      return `<${name}${output.map(([key, value]) => ` ${key}="${escape(value)}"`).join("")}${tag.endsWith("/>") ? "/>" : ">"}${background}`;
    });
  }

  globalThis.__peleRender = (source, optionsJson) => {
    try {
      const options = JSON.parse(optionsJson);
      const theme = options.theme ?? {};
      const transparent = options.transparentBackground !== false;
      const nativeText = options.measureText !== false && typeof __peleMeasureText === "function";
      delete options.measureText;
      delete options.theme;
      delete options.transparentBackground;
      if (nativeText) {
        options.measurer = {width(text, size, style) {
          const family = (style & 4 ? options.fontFamilyMono : options.fontFamily) ?? "sans-serif";
          const effectiveSize = style & (8 | 16) ? size / 1.2 : size;
          const key = JSON.stringify([family, effectiveSize, style, text]);
          let width = textWidths.get(key);
          if (width === undefined) {
            width = __peleMeasureText(text, effectiveSize, style, family.replace(/["']/g, ""));
            if (textWidths.size >= 10000) textWidths.clear();
            textWidths.set(key, width);
          }
          return width;
        }};
      }
      // The host does not fetch resources or execute diagram callbacks.
      options.images = false;
      options.links = false;
      options.responsive = false;
      options.limit = Math.min(options.limit ?? 50000, 50000);
      options.outputLimit = Math.min(options.outputLimit ?? 4000000, 4000000);
      options.maxEdges = Math.min(options.maxEdges ?? 5000, 5000);
      const result = pele.render(source, options);
      result.svg = portableSvg(result.svg, theme, transparent);
      result.textMeasurement = nativeText ? "native" : "estimate";
      return JSON.stringify({ok: true, ...result});
    } catch (error) {
      return JSON.stringify({ok: false, error: {
        code: error.code ?? "render", message: error.message ?? String(error),
        type: error.type ?? null, line: error.line ?? 0,
        column: error.column ?? 0, snippet: error.snippet ?? ""
      }});
    }
  };
})();
