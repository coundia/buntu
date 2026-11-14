import { render } from 'solid-js/web';
import { App } from './app/App';
import { installFlexGapShim } from './ui/design/flexGapShim';
import { applyAccessibilityPrefs, getAccessibilityPrefs } from './ui/design/accessibilityPrefs';
import './ui/design/theme.css';

// Apply flexbox gap polyfill on Samsung Tizen TVs with Chromium < 84
installFlexGapShim();
// Apply saved TV accessibility preferences (high contrast & text size) before first paint
applyAccessibilityPrefs(getAccessibilityPrefs());

const root = document.getElementById('app');
if (root) {
  render(() => <App />, root);
}

