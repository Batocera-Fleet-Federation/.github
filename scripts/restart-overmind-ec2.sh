<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Batocera Fleet Federation</title>
  <style>
    /* Existing styles assumed here */

    /* Landing page wrapper uses dark background consistent with Overmind/Hive theme */
    #landing-page {
      background: var(--background-gradient, #121212);
      color: var(--text-color, #ddd);
      padding: 2rem 1rem;
      display: flex;
      flex-direction: column;
      align-items: center;
      font-family: var(--font-family, 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif);
      min-height: 100vh;
    }

    #landing-content {
      max-width: 1200px;
      width: 100%;
      display: flex;
      flex-direction: column;
      gap: 2rem;
    }

    /* Intro text */
    #landing-intro {
      font-size: 1.25rem;
      font-weight: 500;
      line-height: 1.5;
      color: var(--text-color, #ddd);
      margin-bottom: 1rem;
      text-align: center;
      max-width: 900px;
      margin-left: auto;
      margin-right: auto;
    }

    /* Feature strip */
    #feature-strip {
      display: flex;
      justify-content: center;
      gap: 2rem;
      flex-wrap: wrap;
      max-width: 900px;
      margin-left: auto;
      margin-right: auto;
      color: var(--muted-text, #999);
      font-size: 1rem;
    }
    #feature-strip > div {
      background: var(--card-bg, #1e1e1e);
      border: 1px solid var(--border-color, #333);
      box-shadow: var(--card-shadow, 0 2px 8px rgba(0,0,0,0.7));
      border-radius: 8px;
      padding: 0.75rem 1.25rem;
      flex: 1 1 180px;
      text-align: center;
      font-weight: 600;
      color: var(--accent-color, #58a6ff);
      user-select: none;
    }

    /* Panels/cards use existing card style */
    .panel {
      background: var(--card-bg, #1e1e1e);
      border: 1px solid var(--border-color, #333);
      box-shadow: var(--card-shadow, 0 2px 8px rgba(0,0,0,0.7));
      border-radius: 8px;
      padding: 1rem 1.5rem;
      color: var(--text-color, #ddd);
      max-width: 900px;
      margin-left: auto;
      margin-right: auto;
    }

    /* Buttons re-styled to theme and wired to existing handlers */
    #landing-buttons {
      display: flex;
      justify-content: center;
      gap: 1.5rem;
      margin-bottom: 2rem;
    }
    #landing-buttons button {
      background: var(--accent-color, #58a6ff);
      border: none;
      border-radius: 6px;
      color: #121212;
      font-weight: 600;
      font-size: 1rem;
      padding: 0.6rem 1.5rem;
      cursor: pointer;
      box-shadow: var(--button-shadow, 0 2px 6px rgba(0,0,0,0.5));
      transition: background-color 0.3s ease;
    }
    #landing-buttons button:hover,
    #landing-buttons button:focus {
      background: var(--accent-hover, #3a7bd5);
      outline: none;
    }

    /* Landing image styling */
    #landing-image-container {
      max-width: 1200px;
      width: 100%;
      margin: 0 auto;
      margin-top: 2rem;
      border-radius: 12px;
      overflow: hidden;
      border: 1px solid var(--border-color, #333);
      box-shadow: var(--card-shadow, 0 4px 16px rgba(0,0,0,0.75));
    }
    #landing-image-container img {
      width: 100%;
      height: auto;
      display: block;
      border-radius: 12px;
    }
  </style>
</head>
<body>
  <!-- Other authenticated page content here -->

  <!-- Unauthenticated landing page section -->
  <section id="landing-page" aria-label="Landing page">
    <div id="landing-content">

      <div id="landing-intro">
        Batocera Fleet Federation lets you monitor and manage a group of Batocera arcade and retro gaming machines from one Overmind dashboard. Connect Drones, see machine health, review ROM and configuration visibility, and trigger safe fleet actions — all without SSHing into every box.
      </div>

      <div id="feature-strip" aria-label="What this does">
        <div>See every arcade machine</div>
        <div>Know what is installed</div>
        <div>Connect machines into a swarm</div>
        <div>Manage safely from one place</div>
      </div>

      <div id="landing-buttons" role="group" aria-label="Login and Register">
        <button id="btn-login" type="button">Login</button>
        <button id="btn-register" type="button">Register</button>
      </div>

      <div class="panel" id="quick-install-panel" aria-label="Quick install: Drone on a Batocera machine">
        <!-- Existing quick install content preserved here -->
        <h2>Quick install: Drone on a Batocera machine</h2>
        <p>Follow these steps to quickly install the Drone component on your Batocera machine and connect it to your fleet.</p>
        <ol>
          <li>Download the Drone package from the releases page.</li>
          <li>Copy it to your Batocera machine via USB or network.</li>
          <li>Run the installation script on the Batocera machine.</li>
          <li>Configure the Drone with your Overmind dashboard address.</li>
          <li>Start the Drone service and verify it appears in your fleet.</li>
        </ol>
      </div>

      <div class="panel" id="tips-panel" aria-label="Tips">
        <!-- Existing tips content preserved here -->
        <h2>Tips</h2>
        <ul>
          <li>Ensure your Batocera machines are on the same network as your Overmind dashboard.</li>
          <li>Use the Fleet Federation dashboard to monitor machine health and activity.</li>
          <li>Review ROM and config visibility settings to control access.</li>
          <li>Trigger fleet-wide actions safely without manual SSH sessions.</li>
        </ul>
      </div>

      <div id="landing-image-container" aria-label="Landing page illustration">
        <img src="images/landing-illustration.png" alt="Illustration showing Batocera Fleet Federation dashboard with connected machines" />
      </div>

    </div>
  </section>

  <script>
    // Assuming the app uses hash routing or existing functions to show login/register forms.
    // Wire buttons to existing handlers or routes.

    // Check if existing functions exist
    function showLogin() {
      if (typeof window.showLoginScreen === 'function') {
        window.showLoginScreen();
      } else if (typeof window.showLogin === 'function') {
        window.showLogin();
      } else {
        // fallback to hash routing
        location.hash = '#login';
      }
    }
    function showRegister() {
      if (typeof window.showRegisterScreen === 'function') {
        window.showRegisterScreen();
      } else if (typeof window.showRegister === 'function') {
        window.showRegister();
      } else {
        // fallback to hash routing
        location.hash = '#register';
      }
    }

    document.getElementById('btn-login').addEventListener('click', showLogin);
    document.getElementById('btn-register').addEventListener('click', showRegister);
  </script>
</body>
</html>