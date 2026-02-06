import { BridgeComponent } from "@hotwired/hotwire-native-bridge";

export default class extends BridgeComponent {
  static component = "navigation";
  static values = { config: String };

  connect() {
    super.connect();
    this.#sendTabConfiguration();
  }

  configValueChanged() {
    this.#sendTabConfiguration();
  }

  #sendTabConfiguration() {
    this.send("configure", JSON.parse(this.configValue));
  }
}
