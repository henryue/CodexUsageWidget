import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.dirname(fileURLToPath(import.meta.url));
const darkDir = path.join(root, "Variants", "Dark");
const monoDir = path.join(root, "Variants", "Mono");
const composerAssetsDir = path.resolve(root, "../../App/IconSource/AppIcon.icon/Assets");
const syncComposer = process.argv.includes("--sync-composer");
fs.mkdirSync(darkDir, { recursive: true });
fs.mkdirSync(monoDir, { recursive: true });

const palette = {
  light: { background: "#FDF8F4", outer: "#042249", inner: "#026CEF", dot: "#00DCFF" },
  dark: { background: "#050F25", outer: "#D6E8FB", inner: "#0296FF", dot: "#64D2FF" },
  mono: { background: "#181818", outer: "#FFFFFF", inner: "#A6A6A6", dot: "#FFFFFF", dotOpacity: 0.82 },
};

const outerWidth = 100;
const innerWidth = 72;

const smoothstep = (t) => 3 * t * t - 2 * t * t * t;

function outerRadius(degrees) {
  if (degrees <= 75) {
    return 291 + 15 * smoothstep((degrees - 20) / 55);
  }
  if (degrees <= 295) return 306;
  return 306 - 4 * smoothstep((degrees - 295) / 28);
}

function innerRadius(degrees) {
  if (degrees <= 290) return 180;
  return 180 - 7 * smoothstep((degrees - 290) / 29);
}

function point(radius, degrees) {
  const radians = (degrees * Math.PI) / 180;
  return [512 + radius * Math.cos(radians), 512 + radius * Math.sin(radians)];
}

function formatPoint([x, y]) {
  return `${x.toFixed(2)} ${y.toFixed(2)}`;
}

function outlinedArc(start, end, width, radiusAt) {
  const outer = [];
  const inner = [];
  for (let degrees = start; degrees <= end; degrees += 1) {
    outer.push(point(radiusAt(degrees) + width / 2, degrees));
  }
  for (let degrees = end; degrees >= start; degrees -= 1) {
    inner.push(point(radiusAt(degrees) - width / 2, degrees));
  }
  const body = [
    `M ${formatPoint(outer[0])}`,
    ...outer.slice(1).map((value) => `L ${formatPoint(value)}`),
    ...inner.map((value) => `L ${formatPoint(value)}`),
    "Z",
  ].join(" ");
  const startPoint = point(radiusAt(start), start);
  const endPoint = point(radiusAt(end), end);
  return { body, startPoint, endPoint, capRadius: width / 2 };
}

const outerGeometry = outlinedArc(20, 323, outerWidth, outerRadius);
const innerGeometry = outlinedArc(90, 319, innerWidth, innerRadius);

function layerSvg(geometry, fill) {
  return `<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <g fill="${fill}">
    <path d="${geometry.body}"/>
    <circle cx="${geometry.startPoint[0].toFixed(2)}" cy="${geometry.startPoint[1].toFixed(2)}" r="${geometry.capRadius}"/>
    <circle cx="${geometry.endPoint[0].toFixed(2)}" cy="${geometry.endPoint[1].toFixed(2)}" r="${geometry.capRadius}"/>
  </g>
</svg>
`;
}

function dotSvg(fill, opacity = 1) {
  return `<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <circle cx="784" cy="454" r="40" fill="${fill}"${opacity === 1 ? "" : ` fill-opacity="${opacity}"`}/>
</svg>
`;
}

function previewSvg(colors) {
  return `<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <rect width="1024" height="1024" fill="${colors.background}"/>
  <g fill="${colors.outer}"><path d="${outerGeometry.body}"/><circle cx="${outerGeometry.startPoint[0].toFixed(2)}" cy="${outerGeometry.startPoint[1].toFixed(2)}" r="${outerWidth / 2}"/><circle cx="${outerGeometry.endPoint[0].toFixed(2)}" cy="${outerGeometry.endPoint[1].toFixed(2)}" r="${outerWidth / 2}"/></g>
  <g fill="${colors.inner}"><path d="${innerGeometry.body}"/><circle cx="${innerGeometry.startPoint[0].toFixed(2)}" cy="${innerGeometry.startPoint[1].toFixed(2)}" r="${innerWidth / 2}"/><circle cx="${innerGeometry.endPoint[0].toFixed(2)}" cy="${innerGeometry.endPoint[1].toFixed(2)}" r="${innerWidth / 2}"/></g>
  <circle cx="784" cy="454" r="40" fill="${colors.dot}"${colors.dotOpacity ? ` fill-opacity="${colors.dotOpacity}"` : ""}/>
</svg>
`;
}

function writeSet(directory, colors) {
  fs.writeFileSync(path.join(directory, "01-OuterC.svg"), layerSvg(outerGeometry, colors.outer));
  fs.writeFileSync(path.join(directory, "02-InnerC.svg"), layerSvg(innerGeometry, colors.inner));
  fs.writeFileSync(path.join(directory, "03-StatusDot.svg"), dotSvg(colors.dot, colors.dotOpacity));
}

writeSet(root, palette.light);
writeSet(darkDir, palette.dark);
writeSet(monoDir, palette.mono);
if (syncComposer) {
  fs.mkdirSync(composerAssetsDir, { recursive: true });
  writeSet(composerAssetsDir, palette.light);
}
fs.writeFileSync(path.join(root, "Preview-Light.svg"), previewSvg(palette.light));
fs.writeFileSync(path.join(root, "Preview-Dark.svg"), previewSvg(palette.dark));
fs.writeFileSync(path.join(root, "Preview-Mono.svg"), previewSvg(palette.mono));

console.log(`Generated exact Default, Dark, and Mono vector layers${syncComposer ? " and synced Icon Composer assets" : ""}.`);
