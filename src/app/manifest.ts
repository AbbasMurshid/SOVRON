import type { MetadataRoute } from "next";
export default function manifest(): MetadataRoute.Manifest { return { name: "MyLedger", short_name: "MyLedger", description: "Your personal finance, in focus", start_url: "/", display: "standalone", background_color: "#f5f6f4", theme_color: "#f5f6f4", icons: [{ src: "/icon.svg", sizes: "any", type: "image/svg+xml", purpose: "any" }] }; }
