import React from 'react';
import ReactDOM from 'react-dom/client';
import { BrowserRouter } from 'react-router-dom';
import { IconContext } from '@phosphor-icons/react';
import { App } from './App';
import './styles.css';

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode><BrowserRouter><IconContext.Provider value={{ size: 20, weight: 'regular' }}><App /></IconContext.Provider></BrowserRouter></React.StrictMode>,
);
