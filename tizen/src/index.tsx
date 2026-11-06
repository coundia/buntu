import { render } from 'solid-js/web';
import { App } from './app/App';
import './ui/design/theme.css';

const root = document.getElementById('app');
if (root) {
  render(() => <App />, root);
}

