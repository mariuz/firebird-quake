// touch-test.mjs – the touch controls' logic (src/touch.js), without a page: the stick appears where the left
// thumb lands and moves as far as it is pushed (nothing in the dead zone, full speed at its radius, no more
// past it), the right side turns the view by the distance dragged and a quick tap there fires once, held
// buttons stay down until their own touch lifts, and each thumb is followed by its own touch id.
//
//   node scripts/touch-test.mjs

import { TouchControls, STICK_RADIUS, DEAD_ZONE, BUTTONS, MENU_PAD } from '../src/touch.js';

let failed = 0;
const assert = (cond, msg) => { if (!cond) { console.error(`FAIL: ${msg}`); failed++; } else console.log(`ok   ${msg}`); };
const near = (a, b) => Math.abs(a - b) < 1e-9;
const W = 800;

{
  const t = new TouchControls();
  assert(t.axes().knob === null && t.axes().fwd === 0, 'no thumb, no stick, no movement');
  t.start(1, 150, 300, W);
  assert(t.axes().knob?.x0 === 150 && t.axes().knob?.y0 === 300 && t.axes().fwd === 0, 'a thumb on the left half: the stick appears where it landed, not moving yet');
  t.move(1, 150 + DEAD_ZONE * STICK_RADIUS * 0.5, 300);
  assert(t.axes().side === 0, 'inside the dead zone: nothing');
  t.move(1, 150, 300 - STICK_RADIUS / 2);
  assert(near(t.axes().fwd, 0.5) && near(t.axes().side, 0), 'pushed up half the radius: half speed forward');
  t.move(1, 150 + STICK_RADIUS * 3, 300);
  assert(near(t.axes().side, 1) && near(t.axes().knob.dx, STICK_RADIUS), 'pushed right past the radius: full speed sideways, the knob at the rim');
  t.move(1, 150 - STICK_RADIUS, 300 + STICK_RADIUS);
  const a = t.axes();
  assert(near(Math.hypot(a.fwd, a.side), 1) && a.fwd < 0 && a.side < 0, 'pushed down and left: backwards and to the left, no faster than full speed');
  t.start(2, 100, 100, W);
  assert(t.axes().knob.x0 === 150, 'a second thumb on the left does not take the stick');
  t.end(1);
  assert(t.axes().knob === null && t.axes().fwd === 0, 'the thumb lifted: the stick goes, the player stops');
}
{
  const t = new TouchControls({ sensitivity: 0.5 });
  t.start(1, 150, 300, W);
  t.move(1, 150, 250);
  t.start(7, 600, 200, W);
  t.move(7, 640, 210);
  t.move(7, 660, 190);
  let r = t.take();
  assert(near(r.yaw, -30) && near(r.pitch, -5) && r.taps === 0, 'the right side drags the view: 60 px right turns 30° right, 10 px up looks up 5°, while the stick is held');
  assert(near(t.axes().fwd, 50 / STICK_RADIUS), 'and the stick keeps its own thumb');
  r = t.take();
  assert(r.yaw === 0 && r.pitch === 0, 'a read clears the turn');
  t.end(7);
  assert(t.take().taps === 0, 'a drag is not a tap');
  t.start(8, 500, 300, W);
  t.move(8, 503, 302);
  t.end(8);
  assert(t.take().taps === 1, 'a quick touch on the right side is a tap: one shot');
  assert(t.take().taps === 0, 'once');
}
{
  const t = new TouchControls();
  t.hold(3, '+attack');
  t.hold(4, '+jump');
  assert(t.down('+attack') && t.down('+jump'), 'fire and jump held while touched');
  t.end(4);
  assert(t.down('+attack') && !t.down('+jump'), 'jump lets go when its own touch lifts, fire stays');
  assert(t.take().buttons.has('+jump'), 'but the next read still sees the jump: a touch shorter than a tic counts');
  assert(!t.take().buttons.has('+jump') && t.take().buttons.has('+attack'), 'once; fire, still held, is read every time');
  t.release();
  assert(!t.down('+attack') && t.axes().knob === null, 'release (the menu, the window losing focus) lets everything go');
}
assert(BUTTONS.map(([, c]) => c).join() === '+attack,+jump,impulse 10,menu,fullscreen', 'the buttons: fire, jump, the next weapon, the menu, full screen');
assert(MENU_PAD.map(([, k]) => k).join() === 'ArrowUp,ArrowDown,ArrowLeft,ArrowRight,Enter,Escape', "the menu's pad sends the keys the menu reads");

console.log(failed ? `${failed} failure(s)` : 'all touch checks passed');
process.exit(failed ? 1 : 0);
