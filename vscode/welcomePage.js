// Adding background image
const home = globalThis.process?.env?.HOME;

if (home) {
  document.querySelector("body").style.backgroundImage = `url("file://${home}/Downloads/vscode-wallpaper.jpg")`;
  document.querySelector("body").style.backgroundSize = "cover";
  document.querySelector("body").style.backgroundPosition = "center center";
  document.querySelector("body").style.backgroundRepeat = "no-repeat";
  document.querySelector("body").style.backgroundAttachment = "fixed";
}
