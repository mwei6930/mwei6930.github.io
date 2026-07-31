(function () {
  "use strict";

  var STORAGE_PREFIX = "blog-reading-position:";
  var MAX_STATE_AGE_MS = 5 * 60 * 1000;
  var URL_STATE_PARAMS = {
    anchor: "_read_anchor",
    sectionRatio: "_read_section",
    pageRatio: "_read_page",
    timestamp: "_read_time",
  };

  function storageKey(pathname) {
    return STORAGE_PREFIX + pathname;
  }

  function safeSessionSet(key, value) {
    try {
      window.sessionStorage.setItem(key, value);
    } catch (_) {
      // The URL fallback still works when storage is unavailable.
    }
  }

  function safeSessionTake(key) {
    try {
      var value = window.sessionStorage.getItem(key);
      window.sessionStorage.removeItem(key);
      return value;
    } catch (_) {
      return null;
    }
  }

  function validReadingState(state) {
    return (
      state &&
      Number.isFinite(Number(state.sectionRatio)) &&
      Number.isFinite(Number(state.pageRatio)) &&
      Date.now() - Number(state.timestamp || 0) <= MAX_STATE_AGE_MS
    );
  }

  function readingStateFromUrl() {
    var url = new URL(window.location.href);
    var params = url.searchParams;

    if (!params.has(URL_STATE_PARAMS.timestamp)) {
      return null;
    }

    var state = {
      anchor: params.get(URL_STATE_PARAMS.anchor) || null,
      sectionRatio: Number(
        params.get(URL_STATE_PARAMS.sectionRatio) || 0
      ),
      pageRatio: Number(params.get(URL_STATE_PARAMS.pageRatio) || 0),
      timestamp: Number(params.get(URL_STATE_PARAMS.timestamp) || 0),
    };

    Object.values(URL_STATE_PARAMS).forEach(function (name) {
      url.searchParams.delete(name);
    });

    try {
      window.history.replaceState(window.history.state, "", url.href);
    } catch (_) {
      // Some file:// contexts do not allow history replacement.
    }

    return validReadingState(state) ? state : null;
  }

  function attachReadingStateToUrl(url, state) {
    url.searchParams.set(
      URL_STATE_PARAMS.anchor,
      state.anchor || ""
    );
    url.searchParams.set(
      URL_STATE_PARAMS.sectionRatio,
      state.sectionRatio.toFixed(6)
    );
    url.searchParams.set(
      URL_STATE_PARAMS.pageRatio,
      state.pageRatio.toFixed(6)
    );
    url.searchParams.set(
      URL_STATE_PARAMS.timestamp,
      String(state.timestamp)
    );
  }

  function clamp(value, minimum, maximum) {
    return Math.min(Math.max(value, minimum), maximum);
  }

  function documentTop(element) {
    return element.getBoundingClientRect().top + window.scrollY;
  }

  function articleSections() {
    return Array.from(
      document.querySelectorAll("main.content section[id]")
    );
  }

  function captureReadingPosition() {
    var sections = articleSections();
    var maxScroll = Math.max(
      document.documentElement.scrollHeight - window.innerHeight,
      1
    );
    var marker = window.scrollY + 20;
    var currentIndex = -1;

    for (var index = 0; index < sections.length; index += 1) {
      if (documentTop(sections[index]) <= marker) {
        currentIndex = index;
      } else {
        break;
      }
    }

    var state = {
      anchor: null,
      sectionRatio: 0,
      pageRatio: clamp(window.scrollY / maxScroll, 0, 1),
      timestamp: Date.now(),
    };

    if (currentIndex < 0) {
      return state;
    }

    var current = sections[currentIndex];
    var currentTop = documentTop(current);
    var nextTop =
      currentIndex + 1 < sections.length
        ? documentTop(sections[currentIndex + 1])
        : document.documentElement.scrollHeight;
    var sectionHeight = Math.max(nextTop - currentTop, 1);

    state.anchor = current.id;
    state.sectionRatio = clamp(
      (marker - currentTop) / sectionHeight,
      0,
      1
    );
    return state;
  }

  function prepareLanguageLink(event) {
    if (
      event.button !== 0 ||
      event.metaKey ||
      event.ctrlKey ||
      event.shiftKey ||
      event.altKey
    ) {
      return;
    }

    var link = event.currentTarget;
    var target = new URL(link.href, window.location.href);
    var state = captureReadingPosition();

    if (state.anchor) {
      target.hash = state.anchor;
    }

    attachReadingStateToUrl(target, state);
    safeSessionSet(storageKey(target.pathname), JSON.stringify(state));
    link.href = target.href;
  }

  function restoreReadingPosition(state) {
    var maxScroll = Math.max(
      document.documentElement.scrollHeight - window.innerHeight,
      0
    );
    var targetY = state.pageRatio * maxScroll;

    if (state.anchor) {
      var target = document.getElementById(state.anchor);
      var sections = articleSections();
      var currentIndex = sections.indexOf(target);

      if (target && currentIndex >= 0) {
        var currentTop = documentTop(target);
        var nextTop =
          currentIndex + 1 < sections.length
            ? documentTop(sections[currentIndex + 1])
            : document.documentElement.scrollHeight;
        var sectionHeight = Math.max(nextTop - currentTop, 1);

        targetY =
          currentTop + state.sectionRatio * sectionHeight - 20;
      }
    }

    window.scrollTo({
      left: 0,
      top: clamp(targetY, 0, maxScroll),
      behavior: "auto",
    });
  }

  function restoreIncomingPosition() {
    var raw = safeSessionTake(storageKey(window.location.pathname));
    var urlState = readingStateFromUrl();
    var storedState = null;

    if (raw) {
      try {
        storedState = JSON.parse(raw);
      } catch (_) {
        storedState = null;
      }
    }

    var state = validReadingState(storedState)
      ? storedState
      : urlState;
    if (!state) {
      return;
    }

    var userMoved = false;
    var markUserMovement = function () {
      userMoved = true;
    };

    window.addEventListener("wheel", markUserMovement, {
      passive: true,
      once: true,
    });
    window.addEventListener("touchstart", markUserMovement, {
      passive: true,
      once: true,
    });

    var restoreUnlessMoved = function () {
      if (!userMoved) {
        restoreReadingPosition(state);
      }
    };

    window.requestAnimationFrame(restoreUnlessMoved);
    window.setTimeout(restoreUnlessMoved, 160);
    window.setTimeout(restoreUnlessMoved, 700);

    if (document.readyState === "complete") {
      window.setTimeout(restoreUnlessMoved, 0);
    } else {
      window.addEventListener("load", restoreUnlessMoved, {
        once: true,
      });
    }
  }

  function filePreviewProjectRoot() {
    if (window.location.protocol !== "file:") {
      return null;
    }

    var pathname = window.location.pathname.replace(/\\/g, "/");
    var marker = "/source/ipynb/";
    var markerIndex = pathname.toLowerCase().lastIndexOf(marker);
    if (markerIndex < 0) {
      return null;
    }

    return pathname.slice(0, markerIndex);
  }

  function adaptLinksForFilePreview(containers) {
    var projectRoot = filePreviewProjectRoot();
    if (!projectRoot) {
      return;
    }

    containers.forEach(function (container) {
      if (!container) {
        return;
      }

      container.querySelectorAll("a[href]").forEach(function (link) {
        var href = link.getAttribute("href");

        if (href === "/") {
          link.href =
            "file://" + projectRoot + "/public/index.html";
        } else if (/^\/ipynb\//i.test(href)) {
          link.href = "file://" + projectRoot + "/source" + href;
        } else if (href && href.startsWith("/")) {
          link.href = "file://" + projectRoot + "/public" + href;
        }
      });
    });
  }

  function addLanguageSeparator(languageSwitch) {
    var row = languageSwitch.querySelector("p") || languageSwitch;
    row.classList.add("blog-language-row");

    if (row.querySelector(".blog-language-separator")) {
      return;
    }

    var choices = row.querySelectorAll(
      "a[hreflang], span[aria-current='page']"
    );
    if (choices.length !== 2) {
      return;
    }

    var separator = document.createElement("span");
    separator.className = "blog-language-separator";
    separator.setAttribute("aria-hidden", "true");
    separator.textContent = "/";
    row.insertBefore(separator, choices[1]);
  }

  function buildSidebarNavigation() {
    var languageSwitch = document.querySelector(
      ".blog-language-switch"
    );
    var pageNavigation = document.querySelector(".blog-page-nav");
    var marginSidebar = document.getElementById(
      "quarto-margin-sidebar"
    );
    var tableOfContents = document.getElementById("TOC");

    if (
      !pageNavigation ||
      !marginSidebar
    ) {
      return;
    }

    adaptLinksForFilePreview([pageNavigation, languageSwitch]);
    if (languageSwitch) {
      addLanguageSeparator(languageSwitch);
    }

    var isChinese = document.documentElement.lang
      .toLowerCase()
      .startsWith("zh");
    var stack = document.createElement("div");
    stack.className = "blog-reading-sidebar-stack";

    var tools = document.createElement("nav");
    tools.className = "blog-reading-sidebar-tools";
    tools.setAttribute(
      "aria-label",
      isChinese ? "\u9875\u9762\u5bfc\u822a" : "Page navigation"
    );

    var title = document.createElement("div");
    title.className = "blog-reading-sidebar-tools__title";
    title.textContent = isChinese
      ? "\u9875\u9762\u5bfc\u822a"
      : "Page navigation";

    tools.appendChild(title);
    tools.appendChild(pageNavigation);
    if (languageSwitch) {
      tools.appendChild(languageSwitch);
    }

    stack.appendChild(tools);
    if (tableOfContents) {
      marginSidebar.insertBefore(stack, tableOfContents);
      stack.appendChild(tableOfContents);
    } else {
      marginSidebar.appendChild(stack);
    }
    document.body.classList.add("blog-reading-sidebar-enabled");

    if (languageSwitch) {
      languageSwitch
        .querySelectorAll("a[hreflang]")
        .forEach(function (link) {
          link.addEventListener("click", prepareLanguageLink);
        });
    }

    restoreIncomingPosition();
  }

  if (document.readyState === "loading") {
    document.addEventListener(
      "DOMContentLoaded",
      buildSidebarNavigation,
      { once: true }
    );
  } else {
    buildSidebarNavigation();
  }
})();
