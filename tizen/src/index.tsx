import { render } from 'solid-js/web';
import { App } from './app/App';
import { installFlexGapShim } from './ui/design/flexGapShim';
import './ui/design/theme.css';

// Apply flexbox gap polyfill on Samsung Tizen TVs with Chromium < 84
installFlexGapShim();

const root = document.getElementById('app');
if (root) {
  render(() => <App />, root);
}

