import { onPage } from "../engine";
import { bindDemo } from "./demo";
import { bindDocs } from "./docs";
import { bindReady } from "./task";

export function setupMotion() {
  onPage(() => bindReady());
  onPage(() => bindDocs());
  onPage(() => bindDemo());
}
