import brandIcon from "../../src-tauri/icons/128x128.png";

export function BrandMark({
  size = "small",
  decorative = false,
}: {
  size?: "small" | "large";
  decorative?: boolean;
}) {
  return (
    <img
      className={`brand-mark ${size === "large" ? "brand-mark-large" : ""}`}
      src={brandIcon}
      alt={decorative ? "" : "DevPulse"}
      aria-hidden={decorative || undefined}
    />
  );
}
