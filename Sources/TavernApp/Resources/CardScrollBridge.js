// WKWebView is a native scroll boundary even when the page does not overflow. Keep wheel
// gestures in real HTML scrollers, then chain unconsumed gestures to the native container.
(() => {
  function canScroll(element, delta, horizontal) {
    if (!delta || !(element instanceof Element)) return false;
    const style = getComputedStyle(element);
    const root = element === document.scrollingElement;
    let overflow = horizontal ? style.overflowX : style.overflowY;
    // With a visible-overflow HTML root, CSS propagates the body's overflow to the
    // viewport. A tall body with overflow:hidden must not masquerade as a root scroller.
    if (root && element === document.documentElement && document.body
        && style.overflowX === 'visible' && style.overflowY === 'visible') {
      const bodyStyle = getComputedStyle(document.body);
      overflow = horizontal ? bodyStyle.overflowX : bodyStyle.overflowY;
    }
    if (!(/^(auto|scroll|overlay)$/.test(overflow) || (root && overflow === 'visible'))) return false;
    const extent = horizontal ? element.scrollWidth : element.scrollHeight;
    const viewport = root ? (horizontal ? window.innerWidth : window.innerHeight)
      : (horizontal ? element.clientWidth : element.clientHeight);
    const maximum = Math.max(0, extent - viewport);
    if (maximum <= 1) return false;
    const position = horizontal ? element.scrollLeft : element.scrollTop;
    const minimum = horizontal && style.direction === 'rtl' ? -maximum : 0;
    const end = minimum < 0 ? 0 : maximum;
    return delta < 0 ? position > minimum + 1 : position < end - 1;
  }

  window.addEventListener('wheel', event => {
    // Do not turn pinch-to-zoom or a widget's explicitly handled gesture into parent scroll.
    if (event.defaultPrevented || event.ctrlKey) return;
    if (!Number.isFinite(event.deltaX) || !Number.isFinite(event.deltaY)
        || (!event.deltaX && !event.deltaY)) return;
    const path = event.composedPath();
    if (!path.includes(document.scrollingElement)) path.push(document.scrollingElement);
    // A diagonal gesture stays in the widget while either requested axis can still move.
    // Check actual overflow and direction, not the presence of overflow:auto alone.
    if (path.some(element => canScroll(element, event.deltaX, true)
                          || canScroll(element, event.deltaY, false))) return;
    event.preventDefault();
    window.webkit.messageHandlers.tavernScroll.postMessage({
      x: event.deltaX, y: event.deltaY, mode: event.deltaMode
    });
  }, { passive: false });
})();
