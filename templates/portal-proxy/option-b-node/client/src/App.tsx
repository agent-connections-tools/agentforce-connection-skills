import { Chat } from './Chat';
import './App.css';

export default function App() {
  return (
    <div className="app">
      <header className="app-header">
        <h1>{'{ClientName}'} Assistant</h1>
      </header>
      <main className="app-main">
        <Chat />
      </main>
    </div>
  );
}
