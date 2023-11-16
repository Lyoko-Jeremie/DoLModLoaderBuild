const os = require("os");
const fs = require("fs");
const util = require("util");

function setOutput(key, value) {
    // Temporary hack until core actions library catches up with github new recommendations
    const output = process.env['GITHUB_OUTPUT']
    fs.appendFileSync(output, `${key}=${value}${os.EOL}`)
}

;(async () => {
    // game/01-config/sugarcubeConfig.js

    console.log('process.argv.length', process.argv.length);
    console.log('process.argv', process.argv);
    const GameSugarCubeConfigJsFilePath = process.argv[2];
    console.log('GameSugarCubeConfigJsFilePath', GameSugarCubeConfigJsFilePath);
    if (!GameSugarCubeConfigJsFilePath) {
        console.error('no GameSugarCubeConfigJsFilePath');
        process.exit(1);
        return;
    }
    const GameSugarCubeConfigJsF = await (util.promisify(fs.readFile)(GameSugarCubeConfigJsFilePath, {encoding: 'utf-8'}));

    const findR = GameSugarCubeConfigJsF.exec(/version: {0,}"([^"]+)"/);
    if (!findR) {
        console.error('cannot find version reg');
        process.exit(1);
        return;
    }

    const version = findR[1];
    if (!version) {
        console.error('cannot find version string');
        process.exit(1);
        return;
    }
    console.log('GameVersionString:', version);

    setOutput("GameVersionString", version);

    process.exit(0);
})().catch(E => {
    console.error(E);
    process.exit(1);
});

