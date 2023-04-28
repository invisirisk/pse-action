
async function test() {
    console.log("running tests")


    const response = await fetch('https://drive.google.com/uc?export=download&id=1tzTSWJ54w2IjpUjCSnGQqj8ZXhblWEwe');
    const body = await response.text();
    console.log("response received: " + response.status)
    console.log
}

test();
