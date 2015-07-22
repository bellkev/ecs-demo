from flask import Flask
app = Flask(__name__)

@app.route('/')
def hello():
    return 'Hello World! Test 7/22 9:30!'

if __name__ == "__main__":
    app.run()
