import type { Metadata, Viewport } from "next";
import "./globals.css";
export const metadata: Metadata = { title: "MyLedger — Money, in focus", description: "A clear, private space for your personal finances." };
export const viewport: Viewport = { themeColor: "#f5f6f4", width: "device-width", initialScale: 1 };
export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="en"><body>{children}</body></html>;
}
