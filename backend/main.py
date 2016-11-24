from flask import Flask, Response, request
import base64
import random
from os import path
from string import ascii_letters
import subprocess

app = Flask(__name__)

INPUT_PATH = "/home/faebser/workspace/maps-backend/input" # CHANGE THIS
OUTPUT_PATH = "/home/faebser/workspace/maps-backend/output" # CHANGE THIS
COMMAND = "cp {} {}"  # CHANGE THIS


@app.route("/", methods=['GET'])
def main():
    return app.send_static_file('index.html')


@app.route("/sketch-me", methods=["POST"])
def sketch():
    image_string = request.get_json(force=True).get('img', None)
    if image_string is None:
        return Response("property img missing in json", status=500)

    image_data = base64.b64decode(image_string)
    file_name = "".join([random.choice(ascii_letters) for _ in range(0, 40)]) + ".jpeg"
    input_path = path.join(INPUT_PATH, file_name)
    output_path = path.join(OUTPUT_PATH, file_name)
    with open(input_path, 'wb') as f:
        f.write(image_data)

    # this will block
    process = subprocess.Popen(COMMAND.format(input_path, output_path).split(), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    output, error = process.communicate()
    if error is not None and error != '':
        return Response(str(error), status=500)
    else:
        return Response(output_path)

if __name__ == "__main__":
    app.run(processes=5)