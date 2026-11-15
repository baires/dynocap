// Code colors drawn from the site palette: ink for code, muted for comments,
// one warm tone for literals. The accent stays reserved for the ready mark.
const ink = "#F2F2F0";
const soft = "#C8C8C0";
const muted = "#8F8F88";
const literal = "#E6CB8E";

export const dynocapTheme = {
  name: "dynocap",
  type: "dark",
  colors: {
    "editor.background": "#0B0B0A",
    "editor.foreground": ink,
  },
  tokenColors: [
    {
      scope: ["comment", "punctuation.definition.comment"],
      settings: { foreground: muted, fontStyle: "italic" },
    },
    {
      scope: ["string", "constant.other.symbol", "markup.inline.raw"],
      settings: { foreground: literal },
    },
    {
      scope: ["constant.numeric", "constant.language", "support.constant"],
      settings: { foreground: literal },
    },
    {
      scope: ["keyword", "storage", "storage.type", "keyword.operator.new"],
      settings: { foreground: soft },
    },
    {
      scope: [
        "variable.parameter",
        "variable.other.readwrite",
        "meta.object-literal.key",
        "support.type.property-name",
      ],
      settings: { foreground: soft },
    },
    {
      scope: [
        "entity.name.function",
        "support.function",
        "entity.name.command",
      ],
      settings: { foreground: ink },
    },
    {
      scope: [
        "entity.name.type",
        "support.type",
        "support.class",
        "entity.name.class",
      ],
      settings: { foreground: ink },
    },
    {
      scope: ["punctuation", "meta.brace", "keyword.operator"],
      settings: { foreground: muted },
    },
  ],
};
