import '@fontsource-variable/archivo';
import '@fontsource-variable/azeret-mono';
import React from 'react';
import { createRoot } from 'react-dom/client';

import { App } from './App';
import { Hud } from './Hud';
import './styles.css';

const route = window.location.hash.slice(1);
if (route === 'hud') document.body.classList.add('hud-host');
createRoot(document.getElementById('root')!).render(
  <React.StrictMode>{route === 'hud' ? <Hud /> : <App />}</React.StrictMode>
);
